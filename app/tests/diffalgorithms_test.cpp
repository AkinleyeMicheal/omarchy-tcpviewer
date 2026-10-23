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

QTEST_GUILESS_MAIN(DiffAlgorithmsTest)

#include "diffalgorithms_test.moc"
