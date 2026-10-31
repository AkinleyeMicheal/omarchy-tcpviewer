#include "pinstore.h"

#include <QDateTime>

bool PinRecord::isValid() const
{
    if (kind == QStringLiteral("domain"))
        return !domain.isEmpty();
    if (kind == QStringLiteral("ip"))
        return !ip.isEmpty();
    if (kind == QStringLiteral("client"))
        return !clientKey.isEmpty();
    return false;
}

QVariantMap PinRecord::toMap() const
{
    return QVariantMap{
        {QStringLiteral("id"), id},
        {QStringLiteral("kind"), kind},
        {QStringLiteral("title"), title},
        {QStringLiteral("domain"), domain},
        {QStringLiteral("ip"), ip},
        {QStringLiteral("clientKey"), clientKey},
        {QStringLiteral("clientDisplay"), clientDisplay},
        {QStringLiteral("iconPath"), iconPath},
        {QStringLiteral("createdAt"), createdAtMs},
    };
}

PinRecord PinRecord::fromMap(const QVariantMap &map)
{
    PinRecord pin;
    pin.id = map.value(QStringLiteral("id")).toString();
    pin.kind = map.value(QStringLiteral("kind")).toString();
    pin.title = map.value(QStringLiteral("title")).toString();
    pin.domain = map.value(QStringLiteral("domain")).toString();
    pin.ip = map.value(QStringLiteral("ip")).toString();
    pin.clientKey = map.value(QStringLiteral("clientKey")).toString();
    pin.clientDisplay = map.value(QStringLiteral("clientDisplay")).toString();
    pin.iconPath = map.value(QStringLiteral("iconPath")).toString();
    pin.createdAtMs = map.value(QStringLiteral("createdAt")).toLongLong();
    return pin;
}

PinRecord PinStore::upsert(const PinRecord &pin)
{
    // Upstream upsertClientPin/upsertDomainPin: dedupe happens on the stable
    // id, so callers may omit it; an unchanged re-pin keeps its original
    // creation timestamp.
    PinRecord stored = pin;
    if (stored.id.isEmpty()) {
        stored.id = PinStore::idFor(stored.kind,
                                    stored.kind == QStringLiteral("domain")
                                        ? stored.domain
                                        : (stored.kind == QStringLiteral("ip")
                                               ? stored.ip : stored.clientKey));
    }
    if (stored.createdAtMs == 0)
        stored.createdAtMs = QDateTime::currentMSecsSinceEpoch();
    if (!stored.isValid())
        return PinRecord();
    for (const PinRecord &existing : m_pins) {
        if (existing.id == stored.id)
            return existing;
    }
    m_pins.append(stored);
    return stored;
}

bool PinStore::remove(const QString &id)
{
    for (int i = 0; i < m_pins.size(); ++i) {
        if (m_pins.at(i).id == id) {
            m_pins.removeAt(i);
            return true;
        }
    }
    return false;
}

PinRecord PinStore::find(const QString &id) const
{
    for (const PinRecord &pin : m_pins) {
        if (pin.id == id)
            return pin;
    }
    return PinRecord();
}

QVariantList PinStore::toVariantList() const
{
    QVariantList values;
    values.reserve(m_pins.size());
    for (const PinRecord &pin : m_pins)
        values.append(pin.toMap());
    return values;
}

void PinStore::loadFromVariantList(const QVariantList &values)
{
    m_pins.clear();
    for (const QVariant &value : values) {
        const QVariantMap map = value.toMap();
        if (!map.isEmpty() && !map.value(QStringLiteral("id")).toString().isEmpty())
            m_pins.append(PinRecord::fromMap(map));
    }
}

void PinStore::replaceAll(QVector<PinRecord> pins)
{
    m_pins = pins;
}

PinRecord PinStore::fromSessionPin(const QVariantMap &fields)
{
    // IPC file.session_state reply fields (daemon pinValues shape).
    PinRecord pin;
    pin.id = fields.value(QStringLiteral("id")).toString();
    pin.kind = fields.value(QStringLiteral("kind")).toString();
    pin.title = fields.value(QStringLiteral("title")).toString();
    pin.domain = fields.value(QStringLiteral("domain")).toString();
    pin.ip = fields.value(QStringLiteral("ip")).toString();
    pin.clientKey = fields.value(QStringLiteral("client_key")).toString();
    pin.clientDisplay = fields.value(QStringLiteral("client_display_name")).toString();
    pin.iconPath = fields.value(QStringLiteral("client_icon_path")).toString();
    pin.createdAtMs = qint64(fields.value(QStringLiteral("created_at")).toDouble() * 1000.0);
    if (!pin.isValid())
        return PinRecord();
    return pin;
}
