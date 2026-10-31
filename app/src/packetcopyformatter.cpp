#include "packetcopyformatter.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

namespace {

// Upstream copyColumns: number, time, source, destination, domain, client,
// protocol, length, summary, tags. mapKey is a packetRowToMap field, jsonKey
// the stable copied-JSON field name (timeText maps to "time").
constexpr PacketCopyFormatter::CopyColumn kCopyColumns[] = {
    {"number", "number", "#"},
    {"timeText", "time", "Time"},
    {"source", "source", "Source"},
    {"destination", "destination", "Destination"},
    {"domain", "domain", "Domain"},
    {"client", "client", "Client"},
    {"protocol", "protocol", "Protocol"},
    {"length", "length", "Length"},
    {"summary", "summary", "Summary"},
    {"tags", "tags", "Tags"},
};

} // namespace

const PacketCopyFormatter::CopyColumn *PacketCopyFormatter::copyColumns()
{
    return kCopyColumns;
}

PacketCopyFormatter::PacketCopyFormatter(QObject *parent)
    : QObject(parent)
{
}

QString PacketCopyFormatter::cellText(const QVariantMap &row, const CopyColumn &column) const
{
    const QVariant value = row.value(QLatin1String(column.mapKey));
    switch (value.typeId()) {
    case QMetaType::Int:
    case QMetaType::Long:
    case QMetaType::LongLong:
        return QString::number(value.toLongLong());
    case QMetaType::UInt:
    case QMetaType::ULongLong:
        return QString::number(value.toULongLong());
    case QMetaType::Bool:
        return value.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    default:
        return value.toString();
    }
}

QString PacketCopyFormatter::rows(const QVariantList &rows, const QString &format) const
{
    if (rows.isEmpty())
        return {};

    if (format == QStringLiteral("plainText"))
        return plainTextRows(rows);
    if (format == QStringLiteral("json"))
        return jsonRows(rows);
    if (format == QStringLiteral("markdownTable"))
        return markdownTableRows(rows);
    if (format == QStringLiteral("csvWithHeader"))
        return csvRowsWithHeader(rows);
    return csvRows(rows); // csv: the upstream default Copy action
}

QString PacketCopyFormatter::cells(const QStringList &values) const
{
    // Upstream csvValues: one newline-separated CSV value per row.
    QStringList escaped;
    escaped.reserve(values.size());
    for (const QString &value : values)
        escaped.append(csvEscaped(value));
    return escaped.join(QLatin1Char('\n'));
}

QString PacketCopyFormatter::cellFor(const QVariantMap &row, const QVariantMap &column,
                                     const QVariant &customValue) const
{
    if (column.value(QStringLiteral("custom")).toBool())
        return customValue.toString();

    // Same role/field mapping as PacketTableView.readRole ("time" renders
    // timeText; pid/interface/tcpPayloadBytes use their own record names).
    static const QHash<QString, QString> keys = {
        {QStringLiteral("number"), QStringLiteral("number")},
        {QStringLiteral("packetId"), QStringLiteral("packetId")},
        {QStringLiteral("time"), QStringLiteral("timeText")},
        {QStringLiteral("source"), QStringLiteral("source")},
        {QStringLiteral("sourcePort"), QStringLiteral("sourcePort")},
        {QStringLiteral("destination"), QStringLiteral("destination")},
        {QStringLiteral("destinationPort"), QStringLiteral("destinationPort")},
        {QStringLiteral("protocol"), QStringLiteral("protocol")},
        {QStringLiteral("client"), QStringLiteral("client")},
        {QStringLiteral("domain"), QStringLiteral("domain")},
        {QStringLiteral("streamId"), QStringLiteral("streamId")},
        {QStringLiteral("length"), QStringLiteral("length")},
        {QStringLiteral("summary"), QStringLiteral("summary")},
        {QStringLiteral("tcpFlags"), QStringLiteral("tcpFlags")},
        {QStringLiteral("direction"), QStringLiteral("direction")},
        {QStringLiteral("interface"), QStringLiteral("interfaceName")},
        {QStringLiteral("decodeStatus"), QStringLiteral("decodeStatus")},
        {QStringLiteral("sourceKind"), QStringLiteral("sourceKind")},
        {QStringLiteral("tcpPayloadLength"), QStringLiteral("tcpPayloadLength")},
        {QStringLiteral("deltaTime"), QStringLiteral("deltaTime")},
        {QStringLiteral("streamDeltaTime"), QStringLiteral("streamDeltaTime")},
        {QStringLiteral("clientPid"), QStringLiteral("clientPid")},
        {QStringLiteral("bundleIdentifier"), QStringLiteral("bundleIdentifier")},
        {QStringLiteral("comment"), QStringLiteral("comment")},
        {QStringLiteral("tags"), QStringLiteral("tags")},
    };
    const QString role = column.value(QStringLiteral("role")).toString();
    const QString key = keys.value(role);
    if (key.isEmpty())
        return {};

    const QVariant value = row.value(key);
    if (role == QStringLiteral("clientPid"))
        return value.toInt() > 0 ? QString::number(value.toLongLong()) : QString();
    if (role == QStringLiteral("number") || role == QStringLiteral("length"))
        return QString::number(value.toLongLong());
    if (role == QStringLiteral("tcpPayloadLength"))
        return value.toInt() > 0 ? QString::number(value.toLongLong()) : QString();
    return value.toString();
}

QString PacketCopyFormatter::plainTextEscaped(QString value) const
{
    value.replace(QStringLiteral("\r\n"), QStringLiteral(" "));
    value.replace(QLatin1Char('\n'), QChar::fromLatin1(' '));
    value.replace(QLatin1Char('\r'), QChar::fromLatin1(' '));
    value.replace(QLatin1Char('\t'), QChar::fromLatin1(' '));
    return value;
}

QString PacketCopyFormatter::plainTextRows(const QVariantList &rows) const
{
    QStringList lines;
    for (const QVariant &entry : rows) {
        const QVariantMap row = entry.toMap();
        QStringList fields;
        for (int i = 0; i < copyColumnCount; ++i)
            fields.append(plainTextEscaped(cellText(row, copyColumns()[i])));
        lines.append(fields.join(QLatin1Char('\t')));
    }
    return lines.join(QLatin1Char('\n'));
}

QString PacketCopyFormatter::jsonRows(const QVariantList &rows) const
{
    // Upstream JSONRow: every field is a string. QJsonDocument sorts object
    // keys, which JSON treats as unordered.
    QJsonArray array;
    for (const QVariant &entry : rows) {
        const QVariantMap row = entry.toMap();
        QJsonObject object;
        for (int i = 0; i < copyColumnCount; ++i) {
            const CopyColumn column = copyColumns()[i];
            object.insert(QLatin1String(column.jsonKey),
                          QJsonValue(cellText(row, column)));
        }
        array.append(object);
    }
    return QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Indented));
}

QString PacketCopyFormatter::markdownTableRows(const QVariantList &rows) const
{
    QString header = QStringLiteral("| ");
    for (int i = 0; i < copyColumnCount; ++i) {
        if (i > 0)
            header += QStringLiteral(" | ");
        header += QString::fromUtf8(copyColumns()[i].title);
    }
    header += QStringLiteral(" |");

    QString separator = QStringLiteral("| ");
    for (int i = 0; i < copyColumnCount; ++i) {
        if (i > 0)
            separator += QStringLiteral(" | ");
        separator += QStringLiteral("---");
    }
    separator += QStringLiteral(" |");

    QStringList bodyLines;
    for (const QVariant &entry : rows) {
        const QVariantMap row = entry.toMap();
        QString line = QStringLiteral("| ");
        for (int i = 0; i < copyColumnCount; ++i) {
            if (i > 0)
                line += QStringLiteral(" | ");
            QString value = plainTextEscaped(cellText(row, copyColumns()[i]));
            value.replace(QLatin1Char('\\'), QStringLiteral("\\\\"));
            value.replace(QLatin1Char('|'), QStringLiteral("\\|"));
            line += value;
        }
        line += QStringLiteral(" |");
        bodyLines.append(line);
    }

    return header + QLatin1Char('\n') + separator + QLatin1Char('\n')
        + bodyLines.join(QLatin1Char('\n'));
}

QString PacketCopyFormatter::csvEscaped(QString value) const
{
    const bool needsQuoting = value.contains(QLatin1Char(','))
        || value.contains(QLatin1Char('"'))
        || value.contains(QLatin1Char('\n'))
        || value.contains(QLatin1Char('\r'));
    if (!needsQuoting)
        return value;
    value.replace(QLatin1Char('"'), QStringLiteral("\"\""));
    return QLatin1Char('"') + value + QLatin1Char('"');
}

QString PacketCopyFormatter::csvRows(const QVariantList &rows) const
{
    QStringList lines;
    for (const QVariant &entry : rows) {
        const QVariantMap row = entry.toMap();
        QStringList fields;
        for (int i = 0; i < copyColumnCount; ++i)
            fields.append(csvEscaped(cellText(row, copyColumns()[i])));
        lines.append(fields.join(QLatin1Char(',')));
    }
    return lines.join(QLatin1Char('\n'));
}

QString PacketCopyFormatter::csvRowsWithHeader(const QVariantList &rows) const
{
    QStringList fields;
    for (int i = 0; i < copyColumnCount; ++i)
        fields.append(csvEscaped(QString::fromUtf8(copyColumns()[i].title)));

    // An empty selection upstream still copies the header row.
    return fields.join(QLatin1Char(',')) + QLatin1Char('\n') + csvRows(rows);
}
