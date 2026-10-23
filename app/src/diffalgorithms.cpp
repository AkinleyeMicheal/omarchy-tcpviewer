#include "diffalgorithms.h"

#include <QVariantMap>

#include <algorithm>
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
