#include "packetcolumnlayout.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSettings>
#include <QVariantMap>

namespace {

constexpr int maximumCustomColumns = 32;
constexpr int maximumFieldNameLength = 200;
constexpr int maximumTitleLength = 120;
constexpr int maximumColumnWidth = 2'000;
constexpr int minimumColumnWidth = 40;
constexpr int defaultCustomWidth = 140;
constexpr int minimumCustomWidth = 90;

QString settingsValue(const QString &settingsFile)
{
    if (settingsFile.isEmpty()) {
        QSettings settings;
        return settings.value(QStringLiteral("packetTable/columnLayout")).toString();
    }
    QSettings settings(settingsFile, QSettings::IniFormat);
    return settings.value(QStringLiteral("packetTable/columnLayout")).toString();
}

void writeSettingsValue(const QString &settingsFile, const QString &value)
{
    if (settingsFile.isEmpty()) {
        QSettings settings;
        settings.setValue(QStringLiteral("packetTable/columnLayout"), value);
        return;
    }
    QSettings settings(settingsFile, QSettings::IniFormat);
    settings.setValue(QStringLiteral("packetTable/columnLayout"), value);
}

} // namespace

PacketColumnLayout::PacketColumnLayout(QObject *parent, const QString &settingsFile)
    : QObject(parent)
    , m_settingsFile(settingsFile)
{
    m_definitions = defaultDefinitions();
    m_order.reserve(m_definitions.size());
    for (const Definition &definition : m_definitions) {
        m_order.append(definition.identifier);
        m_visibility.insert(definition.identifier, definition.defaultVisible);
        m_widths.insert(definition.identifier, definition.defaultWidth);
    }
    load();
}

QVector<PacketColumnLayout::Definition> PacketColumnLayout::defaultDefinitions()
{
    return {
        {QStringLiteral("number"), QStringLiteral("#"), QStringLiteral("number"), {}, 68, 52, true, true, false},
        {QStringLiteral("time"), QStringLiteral("Time"), QStringLiteral("time"), {}, 112, 96, true, true, false},
        {QStringLiteral("source"), QStringLiteral("Source"), QStringLiteral("source"), {}, 180, 100, true, true, false},
        {QStringLiteral("destination"), QStringLiteral("Destination"), QStringLiteral("destination"), {}, 180, 100, true, true, false},
        {QStringLiteral("sourcePort"), QStringLiteral("Source Port"), QStringLiteral("sourcePort"), {}, 92, 76, false, true, false},
        {QStringLiteral("destinationPort"), QStringLiteral("Destination Port"), QStringLiteral("destinationPort"), {}, 118, 92, false, true, false},
        {QStringLiteral("protocol"), QStringLiteral("Protocol"), QStringLiteral("protocol"), {}, 96, 82, true, true, false},
        {QStringLiteral("client"), QStringLiteral("Client"), QStringLiteral("client"), {}, 140, 60, true, true, false},
        {QStringLiteral("domain"), QStringLiteral("Domain"), QStringLiteral("domain"), {}, 150, 60, true, true, false},
        {QStringLiteral("streamId"), QStringLiteral("Stream ID"), QStringLiteral("streamId"), {}, 96, 76, false, true, false},
        {QStringLiteral("direction"), QStringLiteral("Direction"), QStringLiteral("direction"), {}, 90, 76, false, true, false},
        {QStringLiteral("deltaTime"), QStringLiteral("Delta Time"), QStringLiteral("deltaTime"), {}, 96, 78, false, true, false},
        {QStringLiteral("streamDeltaTime"), QStringLiteral("Stream Delta"), QStringLiteral("streamDeltaTime"), {}, 106, 88, false, true, false},
        {QStringLiteral("tcpFlags"), QStringLiteral("TCP Flags"), QStringLiteral("tcpFlags"), {}, 118, 88, false, true, false},
        {QStringLiteral("tcpPayloadBytes"), QStringLiteral("TCP Payload"), QStringLiteral("tcpPayloadLength"), {}, 104, 86, false, true, false},
        {QStringLiteral("pid"), QStringLiteral("PID"), QStringLiteral("clientPid"), {}, 76, 58, false, true, false},
        {QStringLiteral("bundleIdentifier"), QStringLiteral("Bundle ID"), QStringLiteral("bundleIdentifier"), {}, 220, 120, false, true, false},
        {QStringLiteral("decodeStatus"), QStringLiteral("Decode Status"), QStringLiteral("decodeStatus"), {}, 120, 96, false, true, false},
        {QStringLiteral("interface"), QStringLiteral("Interface"), QStringLiteral("interface"), {}, 112, 84, false, true, false},
        {QStringLiteral("length"), QStringLiteral("Length"), QStringLiteral("length"), {}, 80, 68, true, true, false},
        {QStringLiteral("summary"), QStringLiteral("Summary"), QStringLiteral("summary"), {}, 320, 120, true, true, false},
        {QStringLiteral("tags"), QStringLiteral("Tags"), QStringLiteral("tags"), {}, 140, 90, false, true, false},
        {QStringLiteral("comment"), QStringLiteral("Comment"), QStringLiteral("comment"), {}, 320, 140, true, true, false},
    };
}

QVariantList PacketColumnLayout::columns() const
{
    // Visual order: the persisted column order (comment pinned last), only
    // visible columns.
    QVariantList result;
    for (const QString &identifier : m_order) {
        if (!isVisible(identifier))
            continue;
        const int index = indexOf(identifier);
        if (index < 0)
            continue;
        const Definition &definition = m_definitions.at(index);
        result.append(QVariantMap{
            {QStringLiteral("id"), definition.identifier},
            {QStringLiteral("title"), definition.title},
            {QStringLiteral("role"), definition.role},
            {QStringLiteral("width"), m_widths.value(definition.identifier, definition.defaultWidth)},
            {QStringLiteral("minimumWidth"), definition.minimumWidth},
            {QStringLiteral("custom"), definition.custom},
            {QStringLiteral("field"), definition.fieldName},
        });
    }
    return result;
}

QVariantList PacketColumnLayout::menuEntries() const
{
    const int visible = visibleCountInternal();
    QVariantList result;
    for (const Definition &definition : m_definitions) {
        const bool shown = isVisible(definition.identifier);
        result.append(QVariantMap{
            {QStringLiteral("id"), definition.identifier},
            {QStringLiteral("title"), definition.title},
            {QStringLiteral("visible"), shown},
            {QStringLiteral("enabled"), definition.canHide && (!shown || visible > 1)},
            {QStringLiteral("custom"), definition.custom},
        });
    }
    return result;
}

int PacketColumnLayout::visibleCount() const
{
    return visibleCountInternal();
}

QVariantList PacketColumnLayout::customColumns() const
{
    QVariantList result;
    for (const Definition &definition : m_definitions) {
        if (!definition.custom)
            continue;
        result.append(QVariantMap{
            {QStringLiteral("id"), definition.identifier},
            {QStringLiteral("fieldName"), definition.fieldName},
            {QStringLiteral("title"), definition.title},
        });
    }
    return result;
}

bool PacketColumnLayout::toggleColumn(const QString &identifier)
{
    return setColumnVisible(identifier, !isVisible(identifier));
}

bool PacketColumnLayout::setColumnVisible(const QString &identifier, bool visible)
{
    const int index = indexOf(identifier);
    if (index < 0)
        return false;
    const Definition &definition = m_definitions.at(index);
    if (!visible && (!definition.canHide || visibleCountInternal() <= 1))
        return false;
    if (isVisible(identifier) == visible)
        return false;
    m_visibility.insert(identifier, visible);
    save();
    emitChanged();
    return true;
}

void PacketColumnLayout::resetColumns()
{
    m_order.clear();
    for (const Definition &definition : m_definitions)
        m_order.append(definition.identifier);
    for (const Definition &definition : m_definitions) {
        m_visibility.insert(definition.identifier, definition.defaultVisible);
        m_widths.insert(definition.identifier, definition.defaultWidth);
    }
    save();
    emitChanged();
}

bool PacketColumnLayout::moveColumn(const QString &identifier, int visibleIndex)
{
    // Upstream pins the Comment column last (shouldReorderColumn), so it can
    // never be dragged and nothing is inserted behind it.
    if (identifier == QStringLiteral("comment") || visibleIndex < 0)
        return false;
    if (indexOf(identifier) < 0 || !isVisible(identifier))
        return false;

    QStringList others;
    int from = -1;
    for (const QString &existing : m_order) {
        if (existing == identifier) {
            from = others.size();
            continue;
        }
        if (existing == QStringLiteral("comment"))
            continue;
        if (isVisible(existing))
            others.append(existing);
    }
    if (from < 0 || visibleIndex > others.size())
        return false;
    // Inserting at the same boundary is a no-op (no visible change).
    if (from == visibleIndex)
        return false;
    others.insert(visibleIndex, identifier);

    // Write the list back into the order slots that hold visible columns;
    // hidden entries keep their relative positions and Comment stays last.
    QStringList next;
    auto cursor = others.constBegin();
    for (const QString &existing : m_order) {
        if (existing == QStringLiteral("comment"))
            continue;
        if (isVisible(existing)) {
            if (cursor != others.constEnd())
                next.append(*cursor++);
            continue;
        }
        next.append(existing);
    }
    next.append(QStringLiteral("comment"));
    m_order = next;
    save();
    emitChanged();
    return true;
}

bool PacketColumnLayout::setColumnWidth(const QString &identifier, int width)
{
    const int index = indexOf(identifier);
    if (index < 0)
        return false;
    const Definition &definition = m_definitions.at(index);
    const int next = clampedWidth(width, definition.minimumWidth);
    if (m_widths.value(identifier, definition.defaultWidth) == next)
        return false;
    m_widths.insert(identifier, next);
    save();
    emitChanged();
    return true;
}

int PacketColumnLayout::columnWidth(const QString &identifier) const
{
    const int index = indexOf(identifier);
    if (index < 0)
        return 0;
    return m_widths.value(identifier, m_definitions.at(index).defaultWidth);
}

int PacketColumnLayout::columnMinimumWidth(const QString &identifier) const
{
    const int index = indexOf(identifier);
    return index < 0 ? minimumColumnWidth : m_definitions.at(index).minimumWidth;
}

void PacketColumnLayout::resetColumnWidth(const QString &identifier)
{
    const int index = indexOf(identifier);
    if (index < 0)
        return;
    const Definition &definition = m_definitions.at(index);
    if (m_widths.value(identifier, definition.defaultWidth) == definition.defaultWidth)
        return;
    m_widths.insert(identifier, definition.defaultWidth);
    save();
    emitChanged();
}

QString PacketColumnLayout::createCustomColumn(const QString &fieldName, const QString &title)
{
    const QString normalized = normalizedFieldName(fieldName);
    if (normalized.isEmpty())
        return {};

    for (const Definition &definition : m_definitions) {
        if (!definition.custom || definition.fieldName != normalized)
            continue;
        if (!isVisible(definition.identifier)) {
            m_visibility.insert(definition.identifier, true);
            save();
            emitChanged();
        }
        return definition.identifier;
    }

    if (m_definitions.size() >= maximumCustomColumns + defaultDefinitions().size())
        return {};

    QString identifier = identifierForField(normalized);
    int suffix = 2;
    while (indexOf(identifier) >= 0) {
        identifier = identifierForField(normalized) + QLatin1Char('-') + QString::number(suffix++);
    }

    Definition definition;
    definition.identifier = identifier;
    definition.title = sanitizedTitle(title, normalized);
    definition.role = QStringLiteral("custom");
    definition.fieldName = normalized;
    definition.defaultWidth = defaultCustomWidth;
    definition.minimumWidth = minimumCustomWidth;
    definition.defaultVisible = true;
    definition.canHide = true;
    definition.custom = true;
    m_definitions.append(definition);
    m_visibility.insert(identifier, true);
    m_widths.insert(identifier, defaultCustomWidth);
    // Upstream setCustomColumns keeps custom columns before the trailing
    // Comment column.
    const int commentSlot = m_order.indexOf(QStringLiteral("comment"));
    if (commentSlot >= 0)
        m_order.insert(commentSlot, identifier);
    else
        m_order.append(identifier);
    save();
    emit columnsChanged();
    emit customColumnsChanged();
    return identifier;
}

bool PacketColumnLayout::removeCustomColumn(const QString &identifier)
{
    const int index = indexOf(identifier);
    if (index < 0 || !m_definitions.at(index).custom)
        return false;
    m_definitions.removeAt(index);
    m_order.removeOne(identifier);
    m_visibility.remove(identifier);
    m_widths.remove(identifier);
    save();
    emit columnsChanged();
    emit customColumnsChanged();
    return true;
}

QString PacketColumnLayout::fieldForColumn(const QString &identifier) const
{
    const int index = indexOf(identifier);
    return index < 0 ? QString() : m_definitions.at(index).fieldName;
}

QString PacketColumnLayout::normalizedFieldName(const QString &fieldName)
{
    QString normalized = fieldName.trimmed().toLower();
    if (normalized.size() > maximumFieldNameLength)
        normalized.truncate(maximumFieldNameLength);
    return normalized;
}

QString PacketColumnLayout::identifierForField(const QString &normalizedField)
{
    QString sanitized;
    sanitized.reserve(normalizedField.size());
    bool previousDash = false;
    for (const QChar character : normalizedField) {
        const bool allowed = character.isLetterOrNumber()
            || character == QLatin1Char('.') || character == QLatin1Char('_')
            || character == QLatin1Char('-');
        const QChar next = allowed ? character : QLatin1Char('-');
        if (next == QLatin1Char('-') && previousDash)
            continue;
        sanitized.append(next);
        previousDash = next == QLatin1Char('-');
    }
    while (sanitized.startsWith(QLatin1Char('-')))
        sanitized.remove(0, 1);
    while (sanitized.endsWith(QLatin1Char('-')))
        sanitized.chop(1);
    return QStringLiteral("custom.field.") + (sanitized.isEmpty() ? QStringLiteral("field") : sanitized);
}

QString PacketColumnLayout::sanitizedTitle(const QString &title, const QString &fallback)
{
    QString value = title.trimmed();
    for (int i = 0; i < value.size(); ++i) {
        if (value.at(i).category() == QChar::Other_Control)
            value[i] = QLatin1Char(' ');
    }
    if (value.size() > maximumTitleLength)
        value.truncate(maximumTitleLength);
    return value.isEmpty() ? fallback : value;
}

int PacketColumnLayout::clampedWidth(int width, int minimum)
{
    return qBound(qMax(minimumColumnWidth, minimum), width, maximumColumnWidth);
}

int PacketColumnLayout::indexOf(const QString &identifier) const
{
    for (int i = 0; i < m_definitions.size(); ++i) {
        if (m_definitions.at(i).identifier == identifier)
            return i;
    }
    return -1;
}

bool PacketColumnLayout::isVisible(const QString &identifier) const
{
    return m_visibility.value(identifier, false);
}

int PacketColumnLayout::visibleCountInternal() const
{
    int count = 0;
    for (const Definition &definition : m_definitions) {
        if (isVisible(definition.identifier))
            ++count;
    }
    return count;
}

void PacketColumnLayout::load()
{
    const QString raw = settingsValue(m_settingsFile);
    if (raw.isEmpty())
        return;
    const QJsonDocument document = QJsonDocument::fromJson(raw.toUtf8());
    if (!document.isObject())
        return;
    const QJsonObject root = document.object();
    if (root.value(QStringLiteral("version")).toInt() != 1)
        return;

    // Custom column definitions load first so the ordered columns array can
    // reference them just like the built-ins.
    const QJsonArray custom = root.value(QStringLiteral("customColumns")).toArray();
    QSet<QString> seenFields;
    int added = 0;
    for (const QJsonValue &value : custom) {
        if (added >= maximumCustomColumns || !value.isObject())
            break;
        const QJsonObject object = value.toObject();
        const QString field = normalizedFieldName(object.value(QStringLiteral("fieldName")).toString());
        if (field.isEmpty() || seenFields.contains(field))
            continue;
        seenFields.insert(field);

        QString identifier = identifierForField(field);
        int suffix = 2;
        while (indexOf(identifier) >= 0) {
            identifier = identifierForField(field) + QLatin1Char('-') + QString::number(suffix++);
        }
        Definition definition;
        definition.identifier = identifier;
        definition.title = sanitizedTitle(object.value(QStringLiteral("title")).toString(), field);
        definition.role = QStringLiteral("custom");
        definition.fieldName = field;
        definition.defaultWidth = defaultCustomWidth;
        definition.minimumWidth = minimumCustomWidth;
        definition.defaultVisible = false;
        definition.canHide = true;
        definition.custom = true;
        m_definitions.append(definition);
        m_visibility.insert(identifier,
            object.value(QStringLiteral("visible")).toBool(definition.defaultVisible));
        m_widths.insert(identifier, clampedWidth(
            int(object.value(QStringLiteral("width")).toDouble(defaultCustomWidth)),
            minimumCustomWidth));
        ++added;
    }

    // The persisted columns array is the visual order (upstream restores
    // positions from the same array), not just decoration.
    const QJsonArray columns = root.value(QStringLiteral("columns")).toArray();
    QStringList loadedOrder;
    for (const QJsonValue &value : columns) {
        if (!value.isObject())
            continue;
        const QJsonObject column = value.toObject();
        const QString identifier = column.value(QStringLiteral("identifier")).toString();
        if (indexOf(identifier) < 0 || loadedOrder.contains(identifier))
            continue;
        loadedOrder.append(identifier);
        const Definition &definition = m_definitions.at(indexOf(identifier));
        if (column.value(QStringLiteral("visible")).isBool() && definition.canHide)
            m_visibility.insert(identifier, column.value(QStringLiteral("visible")).toBool());
        if (column.value(QStringLiteral("width")).isDouble()) {
            m_widths.insert(identifier, clampedWidth(
                int(column.value(QStringLiteral("width")).toDouble()), definition.minimumWidth));
        }
    }

    rebuildOrder(loadedOrder);

    if (visibleCountInternal() == 0) {
        for (const Definition &definition : m_definitions) {
            if (definition.defaultVisible) {
                m_visibility.insert(definition.identifier, true);
                break;
            }
        }
    }
}

// Apply a persisted partial order: known identifiers come first in their
// saved sequence, catalog entries the layout never mentioned keep their
// catalog positions after that, and the Comment column is pinned last.
void PacketColumnLayout::rebuildOrder(const QStringList &loadedOrder)
{
    QSet<QString> ordered;
    for (const QString &identifier : loadedOrder)
        if (indexOf(identifier) >= 0 && identifier != QStringLiteral("comment"))
            ordered.insert(identifier);

    QStringList next;
    for (const QString &identifier : loadedOrder) {
        if (ordered.remove(identifier))
            next.append(identifier);
    }
    for (const Definition &definition : m_definitions) {
        if (ordered.contains(definition.identifier)) {
            next.append(definition.identifier);
            ordered.remove(definition.identifier);
        }
    }
    next.append(QStringLiteral("comment"));
    m_order = next;
}

void PacketColumnLayout::save() const
{
    // The columns array is the visual order (upstream writes the table's
    // column order back the same way).
    QJsonArray columns;
    for (const QString &identifier : m_order) {
        const int index = indexOf(identifier);
        if (index < 0)
            continue;
        const Definition &definition = m_definitions.at(index);
        columns.append(QJsonObject{
            {QStringLiteral("identifier"), definition.identifier},
            {QStringLiteral("visible"), isVisible(definition.identifier)},
            {QStringLiteral("width"), m_widths.value(definition.identifier, definition.defaultWidth)},
        });
    }

    QJsonArray custom;
    for (const Definition &definition : m_definitions) {
        if (!definition.custom)
            continue;
        custom.append(QJsonObject{
            {QStringLiteral("fieldName"), definition.fieldName},
            {QStringLiteral("title"), definition.title},
            {QStringLiteral("visible"), isVisible(definition.identifier)},
            {QStringLiteral("width"), m_widths.value(definition.identifier, definition.defaultWidth)},
        });
    }

    const QJsonObject root{
        {QStringLiteral("version"), 1},
        {QStringLiteral("columns"), columns},
        {QStringLiteral("customColumns"), custom},
    };
    writeSettingsValue(m_settingsFile,
        QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact)));
}

void PacketColumnLayout::emitChanged()
{
    emit columnsChanged();
}
