#include "diffalgorithms.h"

#include <QVariantMap>

#include <algorithm>
#include <cstring>
#include <functional>
#include <vector>

namespace {

constexpr int kMaximumDiffLines = 2000; // upstream DiffTextComparison
constexpr int kMaximumNodeDepth = 64;

QStringList splitValueLines(const QString &value)
{
    QString normalized = value;
    normalized.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    normalized.replace(QLatin1Char('\r'), QLatin1Char('\n'));
    return normalized.split(QLatin1Char('\n'));
}

} // namespace

QStringList diffDetailLines(const QVariantList &nodes)
{
    QStringList lines;
    std::function<void(const QVariantMap &, int)> append =
        [&](const QVariantMap &node, int depth) {
            if (depth > kMaximumNodeDepth)
                return;
            const QString name = node.value(QStringLiteral("name")).toString();
            const QString value = node.value(QStringLiteral("value")).toString();
            const QString indent(depth, QLatin1Char('\t'));
            if (value.isEmpty()) {
                lines.append(indent + name);
            } else {
                const QStringList parts = splitValueLines(value);
                lines.append(indent + name + QStringLiteral(": ") + parts.first());
                for (int i = 1; i < parts.size(); ++i)
                    lines.append(indent + parts.at(i));
            }
            const QVariantList children = node.value(QStringLiteral("children")).toList();
            for (const QVariant &child : children)
                append(child.toMap(), depth + 1);
        };

    for (const QVariant &node : nodes)
        append(node.toMap(), 0);
    if (lines.size() > kMaximumDiffLines)
        lines = lines.mid(0, kMaximumDiffLines);
    return lines;
}

QVector<DiffLineEdit> diffLines(const QStringList &left, const QStringList &right)
{
    const QStringList oldLines = left.mid(0, kMaximumDiffLines);
    const QStringList newLines = right.mid(0, kMaximumDiffLines);
    const int n = oldLines.size();
    const int m = newLines.size();

    // Longest-common-subsequence table. uint16_t holds any count up to the
    // 2000-line cap, keeping the worst-case table at ~8 MiB.
    std::vector<quint16> table(static_cast<size_t>(n + 1) * static_cast<size_t>(m + 1), 0);
    const auto at = [&](int i, int j) -> quint16 & {
        return table[static_cast<size_t>(i) * static_cast<size_t>(m + 1) + static_cast<size_t>(j)];
    };

    for (int i = n - 1; i >= 0; --i) {
        for (int j = m - 1; j >= 0; --j) {
            if (oldLines.at(i) == newLines.at(j))
                at(i, j) = static_cast<quint16>(at(i + 1, j + 1) + 1);
            else
                at(i, j) = std::max(at(i + 1, j), at(i, j + 1));
        }
    }

    QVector<DiffLineEdit> edits;
    edits.reserve(n + m);
    int i = 0;
    int j = 0;
    while (i < n && j < m) {
        if (oldLines.at(i) == newLines.at(j)) {
            edits.append({QLatin1Char(' '), oldLines.at(i)});
            ++i;
            ++j;
        } else if (at(i + 1, j) >= at(i, j + 1)) {
            edits.append({QLatin1Char('-'), oldLines.at(i)});
            ++i;
        } else {
            edits.append({QLatin1Char('+'), newLines.at(j)});
            ++j;
        }
    }
    while (i < n)
        edits.append({QLatin1Char('-'), oldLines.at(i++)});
    while (j < m)
        edits.append({QLatin1Char('+'), newLines.at(j++)});
    return edits;
}

DiffByteRange diffBytes(const QByteArray &left, const QByteArray &right)
{
    DiffByteRange range;
    if (left == right)
        return range;

    int prefix = 0;
    const int maximumPrefix = static_cast<int>(std::min(left.size(), right.size()));
    while (prefix < maximumPrefix && left.at(prefix) == right.at(prefix))
        ++prefix;

    int suffix = 0;
    while (suffix < left.size() - prefix && suffix < right.size() - prefix
           && left.at(left.size() - 1 - suffix) == right.at(right.size() - 1 - suffix)) {
        ++suffix;
    }

    range.leftOffset = prefix;
    range.leftLength = static_cast<int>(left.size()) - prefix - suffix;
    range.rightOffset = prefix;
    range.rightLength = static_cast<int>(right.size()) - prefix - suffix;
    return range;
}

namespace {

// Common run long enough to anchor a split. Upstream diffs bytes with
// HexFiend's edit script; anchoring on 8-byte runs approximates the same
// per-instruction granularity without a quadratic byte-level edit pass.
constexpr int kChangeAnchorRun = 8;
// Bound the change list; the envelope highlight still spans dropped middles.
constexpr int kMaximumByteChanges = 512;
// Total anchor-scan work budget so adversarial middles stay merged instead
// of stalling the UI thread.
constexpr qint64 kMaximumAnchorScan = 1 << 20;

void splitByteChanges(const QByteArray &left, int leftStart, int leftEnd,
                      const QByteArray &right, int rightStart, int rightEnd,
                      QVector<DiffByteChangePair> &changes, qint64 &scanBudget)
{
    while (leftStart < leftEnd && rightStart < rightEnd
           && left.at(leftStart) == right.at(rightStart)) {
        ++leftStart;
        ++rightStart;
    }
    while (leftEnd > leftStart && rightEnd > rightStart
           && left.at(leftEnd - 1) == right.at(rightEnd - 1)) {
        --leftEnd;
        --rightEnd;
    }
    if (leftStart == leftEnd && rightStart == rightEnd)
        return;

    if (changes.size() < kMaximumByteChanges && scanBudget > 0
        && leftStart < leftEnd && rightStart < rightEnd) {
        int leftAnchor = -1;
        int rightAnchor = -1;
        int anchorRun = 0;
        for (int li = leftStart; li < leftEnd && leftAnchor < 0; ++li) {
            for (int ri = rightStart; ri < rightEnd; ++ri) {
                if (--scanBudget < 0)
                    break;
                if (left.at(li) != right.at(ri))
                    continue;
                int run = 1;
                while (li + run < leftEnd && ri + run < rightEnd
                       && left.at(li + run) == right.at(ri + run)) {
                    ++run;
                }
                if (run >= kChangeAnchorRun) {
                    leftAnchor = li;
                    rightAnchor = ri;
                    anchorRun = run;
                    break;
                }
            }
        }
        if (leftAnchor >= 0) {
            splitByteChanges(left, leftStart, leftAnchor, right, rightStart, rightAnchor,
                             changes, scanBudget);
            splitByteChanges(left, leftAnchor + anchorRun, leftEnd,
                             right, rightAnchor + anchorRun, rightEnd, changes, scanBudget);
            return;
        }
    }

    if (changes.size() >= kMaximumByteChanges)
        return;
    // An empty side keeps the edit position (upstream's empty Range), so a
    // pure insertion/deletion still reports where it sits.
    DiffByteChangePair change;
    change.leftOffset = leftStart;
    change.leftLength = leftEnd - leftStart;
    change.rightOffset = rightStart;
    change.rightLength = rightEnd - rightStart;
    changes.append(change);
}

} // namespace

QVector<DiffByteChangePair> diffByteChanges(const QByteArray &left, const QByteArray &right)
{
    QVector<DiffByteChangePair> changes;
    if (left == right)
        return changes;
    qint64 scanBudget = kMaximumAnchorScan;
    splitByteChanges(left, 0, static_cast<int>(left.size()),
                     right, 0, static_cast<int>(right.size()), changes, scanBudget);
    return changes;
}

QString byteChangeDescription(const DiffByteChangePair &change)
{
    // Upstream DiffByteChange.description wording, hexadecimal offsets.
    const QString leftHex = QString::number(change.leftOffset, 16).toUpper();
    const QString rightHex = QString::number(change.rightOffset, 16).toUpper();
    if (change.leftLength == 0)
        return QStringLiteral("Added %1 bytes at Right 0x%2").arg(change.rightLength).arg(rightHex);
    if (change.rightLength == 0)
        return QStringLiteral("Removed %1 bytes at Left 0x%2").arg(change.leftLength).arg(leftHex);
    return QStringLiteral("Changed %1 → %2 bytes · Left 0x%3 · Right 0x%4")
        .arg(change.leftLength).arg(change.rightLength).arg(leftHex).arg(rightHex);
}

QByteArray parseHexByteText(const QString &text)
{
    const auto digitValue = [](QChar character) -> int {
        if (character >= QLatin1Char('0') && character <= QLatin1Char('9'))
            return character.unicode() - '0';
        if (character >= QLatin1Char('a') && character <= QLatin1Char('f'))
            return character.unicode() - 'a' + 10;
        if (character >= QLatin1Char('A') && character <= QLatin1Char('F'))
            return character.unicode() - 'A' + 10;
        return -1;
    };
    QByteArray bytes;
    int pending = -1;
    for (const QChar character : text) {
        if (character.isSpace())
            continue;
        const int value = digitValue(character);
        if (value < 0)
            return {}; // Not hex byte text (upstream rejects non-hex digits).
        if (pending < 0) {
            pending = value;
        } else {
            bytes.append(static_cast<char>((pending << 4) | value));
            pending = -1;
        }
    }
    if (pending >= 0)
        return {}; // Odd digit count.
    return bytes;
}

int findByteSequence(const QByteArray &haystack, const QByteArray &needle, int start)
{
    if (needle.isEmpty() || haystack.size() < needle.size())
        return -1;
    const int lastStart = static_cast<int>(haystack.size()) - static_cast<int>(needle.size());
    const int begin = qBound(0, start, lastStart + 1);
    const char *data = haystack.constData();
    for (int i = begin; i <= lastStart; ++i) {
        if (std::memcmp(data + i, needle.constData(), needle.size()) == 0)
            return i;
    }
    // Wrap to the beginning so Find Next always cycles (upstream behavior).
    for (int i = 0; i < begin; ++i) {
        if (std::memcmp(data + i, needle.constData(), needle.size()) == 0)
            return i;
    }
    return -1;
}
