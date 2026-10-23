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

#endif // DIFFALGORITHMS_H
