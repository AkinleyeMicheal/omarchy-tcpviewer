#ifndef DIFFALGORITHMS_H
#define DIFFALGORITHMS_H

#include <QByteArray>
#include <QStringList>
#include <QVariantList>
#include <QVector>

// Pure diff primitives shared by the Diff window and its unit tests.

struct DiffLineEdit {
    QChar marker; // ' ' unchanged, '-' removed, '+' added
    QString text;
};

struct DiffByteRange {
    int leftOffset = -1;
    int leftLength = 0;
    int rightOffset = -1;
    int rightLength = 0;
};

// Flatten a daemon detail tree into upstream DiffPacketTextBuilder lines:
// one tab per level, ": value" only when non-empty, multiline values split.
QStringList diffDetailLines(const QVariantList &nodes);

// Line diff capped at 2000 lines per side (upstream DiffTextComparison).
QVector<DiffLineEdit> diffLines(const QStringList &left, const QStringList &right);

// Byte diff with common prefix/suffix trimming so a length change does not
// mark every following byte as changed.
DiffByteRange diffBytes(const QByteArray &left, const QByteArray &right);

// One byte-level edit (upstream DiffByteChange): an empty side marks a pure
// insertion/deletion, with the offset still pointing at the edit position.
struct DiffByteChangePair {
    int leftOffset = -1;
    int leftLength = 0;
    int rightOffset = -1;
    int rightLength = 0;
};

// Upstream DiffByteChange.description wording (hexadecimal offsets).
QString byteChangeDescription(const DiffByteChangePair &change);

// Byte diff as a list of separated edits (upstream DiffBinaryComparison's
// HFByteArrayEditScript instructions). Splits the differing span on common
// runs so scattered field edits highlight individually; falls back to one
// merged edit when no long common run separates the changes.
QVector<DiffByteChangePair> diffByteChanges(const QByteArray &left, const QByteArray &right);

// Upstream DiffBinarySearch: whitespace-insensitive hex byte pairs ("48 65
// 6C"); an empty result means the text is not valid hex byte text.
QByteArray parseHexByteText(const QString &text);

// First needle occurrence at or after start, wrapping to the beginning
// (upstream DiffBinarySearch.next); -1 without a match.
int findByteSequence(const QByteArray &haystack, const QByteArray &needle, int start);

#endif // DIFFALGORITHMS_H
