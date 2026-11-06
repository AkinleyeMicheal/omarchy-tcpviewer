#include "diffalgorithms.h"

#include <QTest>
#include <QVariantMap>

class DiffAlgorithmsTest : public QObject
{
    Q_OBJECT

private slots:
    void detailLinesUseTabsAndSplitMultilineValues();
    void detailLinesStopAtDepthLimit();
    void lineDiffMarksReplacement();
    void lineDiffDetectsInsertionAndDeletion();
    void lineDiffHandlesEmptySides();
    void byteDiffTrimsCommonEdges();
    void byteDiffReportsPureInsertion();
    void byteDiffEqualHasNoRange();
    void byteChangesSplitScatteredEdits();
    void byteChangesReportInsertionAndDeletion();
    void byteChangesIdenticalIsEmpty();
    void byteSearchParsesHexText();
    void byteSearchFindsAndWraps();
};

void DiffAlgorithmsTest::detailLinesUseTabsAndSplitMultilineValues()
{
    const QVariantMap ack{{QStringLiteral("name"), QStringLiteral("Acknowledgment")},
                          {QStringLiteral("value"), QStringLiteral("1")}};
    const QVariantMap flags{{QStringLiteral("name"), QStringLiteral("Flags")},
                            {QStringLiteral("value"), QStringLiteral("ACK")},
                            {QStringLiteral("children"), QVariantList{ack}}};
    const QVariantMap unicode{{QStringLiteral("name"), QStringLiteral("Unicode")},
                              {QStringLiteral("value"), QStringLiteral("hello\r\nsecond\rthird")}};
    const QVariantMap empty{{QStringLiteral("name"), QStringLiteral("Empty")},
                            {QStringLiteral("value"), QString()}};
    const QVariantMap root{{QStringLiteral("name"), QStringLiteral("TCP")},
                           {QStringLiteral("children"),
                            QVariantList{flags, unicode, empty}}};

    const QStringList expected{
        QStringLiteral("TCP"),
        QStringLiteral("\tFlags: ACK"),
        QStringLiteral("\t\tAcknowledgment: 1"),
        QStringLiteral("\tUnicode: hello"),
        QStringLiteral("\tsecond"),
        QStringLiteral("\tthird"),
        QStringLiteral("\tEmpty"),
    };
    QCOMPARE(diffDetailLines(QVariantList{root}), expected);
}

void DiffAlgorithmsTest::detailLinesStopAtDepthLimit()
{
    // Build a chain deeper than the 64-level guard; the deepest nodes vanish
    // instead of exhausting the stack.
    QVariantMap node{{QStringLiteral("name"), QStringLiteral("leaf")}};
    for (int i = 0; i < 80; ++i) {
        node = QVariantMap{{QStringLiteral("name"), QStringLiteral("level")},
                           {QStringLiteral("children"), QVariantList{node}}};
    }
    const QStringList lines = diffDetailLines(QVariantList{node});
    QVERIFY(!lines.isEmpty());
    QVERIFY(lines.size() <= 66);
}

void DiffAlgorithmsTest::lineDiffMarksReplacement()
{
    const auto edits = diffLines({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")},
                                 {QStringLiteral("a"), QStringLiteral("x"), QStringLiteral("c")});
    QCOMPARE(edits.size(), 4);
    QCOMPARE(edits.at(0).marker, QLatin1Char(' '));
    QCOMPARE(edits.at(1).marker, QLatin1Char('-'));
    QCOMPARE(edits.at(1).text, QStringLiteral("b"));
    QCOMPARE(edits.at(2).marker, QLatin1Char('+'));
    QCOMPARE(edits.at(2).text, QStringLiteral("x"));
    QCOMPARE(edits.at(3).marker, QLatin1Char(' '));
}

void DiffAlgorithmsTest::lineDiffDetectsInsertionAndDeletion()
{
    const auto inserted = diffLines({QStringLiteral("a"), QStringLiteral("c")},
                                    {QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")});
    QCOMPARE(inserted.size(), 3);
    QCOMPARE(inserted.at(1).marker, QLatin1Char('+'));
    QCOMPARE(inserted.at(1).text, QStringLiteral("b"));

    const auto removed = diffLines({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")},
                                   {QStringLiteral("a"), QStringLiteral("c")});
    QCOMPARE(removed.size(), 3);
    QCOMPARE(removed.at(1).marker, QLatin1Char('-'));
    QCOMPARE(removed.at(1).text, QStringLiteral("b"));
}

void DiffAlgorithmsTest::lineDiffHandlesEmptySides()
{
    const auto added = diffLines({}, {QStringLiteral("a")});
    QCOMPARE(added.size(), 1);
    QCOMPARE(added.at(0).marker, QLatin1Char('+'));

    const auto deleted = diffLines({QStringLiteral("a")}, {});
    QCOMPARE(deleted.size(), 1);
    QCOMPARE(deleted.at(0).marker, QLatin1Char('-'));
}

void DiffAlgorithmsTest::byteDiffTrimsCommonEdges()
{
    const QByteArray left = QByteArray::fromHex("0001020304");
    const QByteArray right = QByteArray::fromHex("0001ff0304");
    const DiffByteRange range = diffBytes(left, right);
    QCOMPARE(range.leftOffset, 2);
    QCOMPARE(range.leftLength, 1);
    QCOMPARE(range.rightOffset, 2);
    QCOMPARE(range.rightLength, 1);
}

void DiffAlgorithmsTest::byteDiffReportsPureInsertion()
{
    const DiffByteRange range = diffBytes(QByteArrayLiteral("ab"), QByteArrayLiteral("abXY"));
    QCOMPARE(range.leftOffset, 2);
    QCOMPARE(range.leftLength, 0);
    QCOMPARE(range.rightOffset, 2);
    QCOMPARE(range.rightLength, 2);
}

void DiffAlgorithmsTest::byteDiffEqualHasNoRange()
{
    const DiffByteRange range = diffBytes(QByteArrayLiteral("same"), QByteArrayLiteral("same"));
    QCOMPARE(range.leftOffset, -1);
    QCOMPARE(range.leftLength, 0);
    QCOMPARE(range.rightOffset, -1);
    QCOMPARE(range.rightLength, 0);
}

// Two edits separated by an 8-byte common run highlight individually
// (upstream HFByteArrayEditScript granularity).
void DiffAlgorithmsTest::byteChangesSplitScatteredEdits()
{
    const QByteArray left = QByteArrayLiteral("AAXCCCCCCCCYDD");
    const QByteArray right = QByteArrayLiteral("AAZCCCCCCCCWDD");
    const QVector<DiffByteChangePair> changes = diffByteChanges(left, right);
    QCOMPARE(changes.size(), 2);
    QCOMPARE(changes.at(0).leftOffset, 2);
    QCOMPARE(changes.at(0).leftLength, 1);
    QCOMPARE(changes.at(0).rightOffset, 2);
    QCOMPARE(changes.at(0).rightLength, 1);
    QCOMPARE(changes.at(1).leftOffset, 11);
    QCOMPARE(changes.at(1).leftLength, 1);
    QCOMPARE(changes.at(1).rightOffset, 11);
    QCOMPARE(changes.at(1).rightLength, 1);
    QCOMPARE(byteChangeDescription(changes.at(0)),
             QStringLiteral("Changed 1 → 1 bytes · Left 0x2 · Right 0x2"));
}

void DiffAlgorithmsTest::byteChangesReportInsertionAndDeletion()
{
    const QVector<DiffByteChangePair> added = diffByteChanges(
        QByteArrayLiteral("ab"), QByteArrayLiteral("abXY"));
    QCOMPARE(added.size(), 1);
    QCOMPARE(added.at(0).leftOffset, 2);
    QCOMPARE(added.at(0).leftLength, 0);
    QCOMPARE(added.at(0).rightOffset, 2);
    QCOMPARE(added.at(0).rightLength, 2);
    QCOMPARE(byteChangeDescription(added.at(0)),
             QStringLiteral("Added 2 bytes at Right 0x2"));

    const QVector<DiffByteChangePair> removed = diffByteChanges(
        QByteArrayLiteral("abXY"), QByteArrayLiteral("ab"));
    QCOMPARE(removed.size(), 1);
    QCOMPARE(removed.at(0).leftOffset, 2);
    QCOMPARE(removed.at(0).leftLength, 2);
    QCOMPARE(removed.at(0).rightOffset, 2);
    QCOMPARE(removed.at(0).rightLength, 0);
    QCOMPARE(byteChangeDescription(removed.at(0)),
             QStringLiteral("Removed 2 bytes at Left 0x2"));
}

void DiffAlgorithmsTest::byteChangesIdenticalIsEmpty()
{
    QVERIFY(diffByteChanges(QByteArrayLiteral("same"), QByteArrayLiteral("same")).isEmpty());
    // Empty vs non-empty is one change covering the whole right side.
    const QVector<DiffByteChangePair> changes = diffByteChanges({}, QByteArrayLiteral("abcd"));
    QCOMPARE(changes.size(), 1);
    QCOMPARE(changes.at(0).leftOffset, 0);
    QCOMPARE(changes.at(0).leftLength, 0);
    QCOMPARE(changes.at(0).rightOffset, 0);
    QCOMPARE(changes.at(0).rightLength, 4);
}

void DiffAlgorithmsTest::byteSearchParsesHexText()
{
    // Whitespace-insensitive pairs, mixed case (upstream DiffBinarySearch).
    const QByteArray parsed = parseHexByteText(QStringLiteral("48 65  6c"));
    QCOMPARE(parsed.size(), 3);
    QCOMPARE(static_cast<unsigned char>(parsed.at(0)), 0x48);
    QCOMPARE(static_cast<unsigned char>(parsed.at(1)), 0x65);
    QCOMPARE(static_cast<unsigned char>(parsed.at(2)), 0x6c);
    // Odd digit counts, non-hex digits, and empty text are invalid.
    QVERIFY(parseHexByteText(QStringLiteral("486")).isEmpty());
    QVERIFY(parseHexByteText(QStringLiteral("zz")).isEmpty());
    QVERIFY(parseHexByteText(QStringLiteral("")).isEmpty());
    // Split pairs across spaces still parse ("4 86c" → 48 6c).
    const QByteArray split = parseHexByteText(QStringLiteral("4 8 6 c"));
    QCOMPARE(split.size(), 2);
    QCOMPARE(static_cast<unsigned char>(split.at(0)), 0x48);
    QCOMPARE(static_cast<unsigned char>(split.at(1)), 0x6c);
}

void DiffAlgorithmsTest::byteSearchFindsAndWraps()
{
    const QByteArray haystack = QByteArray::fromHex("48656c6c6f00576f726c64"); // Hello<NUL>World
    QCOMPARE(findByteSequence(haystack, QByteArrayLiteral("Wo"), 0), 6);
    // Continues after the selection start.
    QCOMPARE(findByteSequence(haystack, QByteArrayLiteral("l"), 4), 9);
    // Wraps to the beginning (upstream Find Next cycling).
    QCOMPARE(findByteSequence(haystack, QByteArrayLiteral("He"), 3), 0);
    QVERIFY(findByteSequence(haystack, QByteArrayLiteral("zz"), 0) < 0);
    // Needles longer than the haystack never match.
    QVERIFY(findByteSequence(QByteArrayLiteral("ab"), QByteArrayLiteral("abc"), 0) < 0);
    QVERIFY(findByteSequence(haystack, {}, 0) < 0);
}

QTEST_GUILESS_MAIN(DiffAlgorithmsTest)

#include "diffalgorithms_test.moc"
