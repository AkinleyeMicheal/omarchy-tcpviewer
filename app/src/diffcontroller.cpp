#include "diffcontroller.h"

#include <QStringList>
#include <QUuid>
#include <QVariantMap>

#include <algorithm>

namespace {

constexpr int kMaximumPoolEntries = 500; // upstream DiffPoolModel

} // namespace

// MARK: - DiffPoolModel

DiffPoolModel::DiffPoolModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int DiffPoolModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_entries.size();
}

QVariant DiffPoolModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_entries.size())
        return {};
    const Entry &entry = m_entries.at(index.row());
    switch (role) {
    case EntryIdRole:
        return entry.entryID;
    case PacketIdRole:
        return entry.packetID;
    case SourceIdRole:
        return entry.sourceID;
    case NumberRole:
        return QVariant::fromValue(entry.number);
    case SummaryRole:
        return entry.summary;
    case SideRole:
        return entry.side;
    default:
        return {};
    }
}

QHash<int, QByteArray> DiffPoolModel::roleNames() const
{
    return {
        {EntryIdRole, QByteArrayLiteral("entryId")},
        {PacketIdRole, QByteArrayLiteral("packetId")},
        {SourceIdRole, QByteArrayLiteral("sourceId")},
        {NumberRole, QByteArrayLiteral("number")},
        {SummaryRole, QByteArrayLiteral("summary")},
        {SideRole, QByteArrayLiteral("side")},
    };
}

QString DiffPoolModel::add(const QString &sourceID, const QString &packetID,
                           quint64 number, const QString &summary)
{
    if (sourceID.isEmpty() || packetID.isEmpty())
        return {};

    for (const Entry &entry : m_entries) {
        if (entry.sourceID == sourceID && entry.packetID == packetID)
            return entry.entryID;
    }
    if (m_entries.size() >= kMaximumPoolEntries)
        return {};

    QString side;
    if (indexForSide(QStringLiteral("left")) < 0)
        side = QStringLiteral("left");
    else if (indexForSide(QStringLiteral("right")) < 0)
        side = QStringLiteral("right");

    Entry entry;
    entry.entryID = QUuid::createUuid().toString(QUuid::WithoutBraces);
    entry.sourceID = sourceID;
    entry.packetID = packetID;
    entry.number = number;
    entry.summary = summary;
    entry.side = side;

    beginInsertRows(QModelIndex(), m_entries.size(), m_entries.size());
    m_entries.append(entry);
    endInsertRows();
    emit countChanged();

    if (!side.isEmpty())
        emit sidesChanged();
    return entry.entryID;
}

void DiffPoolModel::setSide(const QString &entryID, const QString &side)
{
    if (side != QLatin1String("left") && side != QLatin1String("right") && !side.isEmpty())
        return;
    const int row = indexForEntry(entryID);
    if (row < 0)
        return;

    // Clicking the active side clears it; choosing the other side moves the
    // entry (only one Left and one Right, matching upstream checkboxes).
    const QString target = m_entries.at(row).side == side ? QString() : side;
    if (m_entries.at(row).side == target)
        return;

    if (!target.isEmpty()) {
        const int other = indexForSide(target);
        if (other >= 0 && other != row) {
            m_entries[other].side.clear();
            const QModelIndex otherIndex = index(other);
            emit dataChanged(otherIndex, otherIndex, {SideRole});
        }
    }

    m_entries[row].side = target;
    const QModelIndex changedIndex = index(row);
    emit dataChanged(changedIndex, changedIndex, {SideRole});
    emit sidesChanged();
}

void DiffPoolModel::removeEntry(const QString &entryID)
{
    const int row = indexForEntry(entryID);
    if (row < 0)
        return;
    const bool hadSide = !m_entries.at(row).side.isEmpty();
    beginRemoveRows(QModelIndex(), row, row);
    m_entries.removeAt(row);
    endRemoveRows();
    emit countChanged();
    if (hadSide)
        emit sidesChanged();
}

void DiffPoolModel::clear()
{
    if (m_entries.isEmpty())
        return;
    beginResetModel();
    m_entries.clear();
    endResetModel();
    emit countChanged();
    emit sidesChanged();
}

QString DiffPoolModel::sideForEntry(const QString &entryID) const
{
    const int row = indexForEntry(entryID);
    return row < 0 ? QString() : m_entries.at(row).side;
}

QString DiffPoolModel::entryIDForSide(const QString &side) const
{
    const int row = indexForSide(side);
    return row < 0 ? QString() : m_entries.at(row).entryID;
}

QString DiffPoolModel::packetIDForEntry(const QString &entryID) const
{
    const int row = indexForEntry(entryID);
    return row < 0 ? QString() : m_entries.at(row).packetID;
}

QString DiffPoolModel::sourceIDForEntry(const QString &entryID) const
{
    const int row = indexForEntry(entryID);
    return row < 0 ? QString() : m_entries.at(row).sourceID;
}

QString DiffPoolModel::summaryForEntry(const QString &entryID) const
{
    const int row = indexForEntry(entryID);
    return row < 0 ? QString() : m_entries.at(row).summary;
}

quint64 DiffPoolModel::numberForEntry(const QString &entryID) const
{
    const int row = indexForEntry(entryID);
    return row < 0 ? 0 : m_entries.at(row).number;
}

int DiffPoolModel::indexForEntry(const QString &entryID) const
{
    for (int i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).entryID == entryID)
            return i;
    }
    return -1;
}

int DiffPoolModel::indexForSide(const QString &side) const
{
    if (side.isEmpty())
        return -1;
    for (int i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).side == side)
            return i;
    }
    return -1;
}

// MARK: - DiffController

DiffController::DiffController(QObject *parent)
    : QObject(parent)
    , m_pool(new DiffPoolModel(this))
{
    m_left.client = new DaemonClient(this);
    m_right.client = new DaemonClient(this);

    for (Side *side : {&m_left, &m_right}) {
        DaemonClient *client = side->client;
        connect(client, &DaemonClient::response, this,
                [this, side](const QString &command, const QVariantMap &data) {
            handleResponse(*side, command, data);
        });
        connect(client, &DaemonClient::failure, this,
                [this, side](const QString &command, const QString &, const QString &message) {
            handleFailure(*side, command, message);
        });
        connect(client, &DaemonClient::connectedChanged, this, [this, side]() {
            if (!side->client->connected() || side->entryID.isEmpty())
                return;
            if (!side->detailsLoaded || !side->bytesLoaded)
                requestSide(*side);
        });
        client->start();
    }

    connect(m_pool, &DiffPoolModel::sidesChanged, this, &DiffController::updateSides);

    // CI/screenshot hooks (same-user environment, not a security boundary).
    const QString mode = qEnvironmentVariable("TCPVIEWER_DIFF_MODE");
    if (mode == QLatin1String("unified"))
        m_displayMode = mode;
    const QString content = qEnvironmentVariable("TCPVIEWER_DIFF_CONTENT");
    if (content == QLatin1String("bytes"))
        m_contentKind = content;
}

bool DiffController::sideReady(const Side &side) const
{
    if (side.entryID.isEmpty())
        return false;
    return m_contentKind == QLatin1String("bytes") ? side.bytesLoaded : side.detailsLoaded;
}

bool DiffController::ready() const
{
    return sideReady(m_left) && sideReady(m_right)
        && m_left.error.isEmpty() && m_right.error.isEmpty();
}

bool DiffController::loading() const
{
    return !m_left.entryID.isEmpty() && !m_right.entryID.isEmpty() && !ready()
        && m_left.error.isEmpty() && m_right.error.isEmpty();
}

QString DiffController::error() const
{
    QStringList errors;
    if (!m_left.error.isEmpty())
        errors.append(m_left.error);
    if (!m_right.error.isEmpty())
        errors.append(m_right.error);
    return errors.join(QLatin1Char('\n'));
}

QString DiffController::titleForSide(const QString &side) const
{
    const QString entryID = m_pool->entryIDForSide(side);
    if (entryID.isEmpty())
        return {};
    const quint64 number = m_pool->numberForEntry(entryID);
    const QString summary = m_pool->summaryForEntry(entryID);
    return summary.isEmpty() ? QStringLiteral("#%1").arg(number)
                             : QStringLiteral("#%1 · %2").arg(number).arg(summary);
}

QString DiffController::leftTitle() const { return titleForSide(QStringLiteral("left")); }
QString DiffController::rightTitle() const { return titleForSide(QStringLiteral("right")); }

void DiffController::setContentKind(const QString &kind)
{
    if (kind != QLatin1String("details") && kind != QLatin1String("bytes"))
        return;
    if (kind == m_contentKind)
        return;
    m_contentKind = kind;
    emit contentKindChanged();
    emit stateChanged();
}

void DiffController::setDisplayMode(const QString &mode)
{
    if (mode != QLatin1String("sideBySide") && mode != QLatin1String("unified"))
        return;
    if (mode == m_displayMode)
        return;
    m_displayMode = mode;
    rebuildChangeRows();
    emit displayModeChanged();
    emit rowsChanged();
}

void DiffController::addPacket(const QString &sourceID, const QString &packetID,
                               quint64 number, const QString &summary)
{
    if (m_pool->add(sourceID, packetID, number, summary).isEmpty())
        return;
}

void DiffController::setSide(const QString &entryID, const QString &side)
{
    m_pool->setSide(entryID, side);
}

void DiffController::removeEntry(const QString &entryID)
{
    m_pool->removeEntry(entryID);
}

void DiffController::clear()
{
    m_pool->clear();
}

void DiffController::updateSides()
{
    const auto sync = [this](Side &side, const QString &sideName) {
        const QString entryID = m_pool->entryIDForSide(sideName);
        if (side.entryID == entryID)
            return;
        side.entryID = entryID;
        side.packetID = entryID.isEmpty() ? QString() : m_pool->packetIDForEntry(entryID);
        side.sourceID = entryID.isEmpty() ? QString() : m_pool->sourceIDForEntry(entryID);
        side.lines.clear();
        side.bytes.clear();
        side.detailsLoaded = false;
        side.bytesLoaded = false;
        side.error.clear();
        if (!entryID.isEmpty() && side.client->connected())
            requestSide(side);
    };

    sync(m_left, QStringLiteral("left"));
    sync(m_right, QStringLiteral("right"));
    recomputeDetails();
    recomputeBytes();
    emit titlesChanged();
    emit stateChanged();
}

void DiffController::requestSide(Side &side)
{
    if (side.packetID.isEmpty())
        return;

    QVariantMap common{
        {QStringLiteral("packet_id"), side.packetID},
        {QStringLiteral("source_id"), side.sourceID},
    };
    if (!side.detailsLoaded) {
        QVariantMap params = common;
        params.insert(QStringLiteral("max_depth"), 12);
        params.insert(QStringLiteral("max_nodes"), 5000);
        side.client->send(QStringLiteral("packets.details"), params, 60);
    }
    if (!side.bytesLoaded) {
        QVariantMap params = common;
        params.insert(QStringLiteral("offset"), 0);
        params.insert(QStringLiteral("length"), 0);
        params.insert(QStringLiteral("encoding"), QStringLiteral("base64"));
        side.client->send(QStringLiteral("packets.bytes"), params, 60);
    }
}

void DiffController::handleResponse(Side &side, const QString &command, const QVariantMap &data)
{
    if (side.packetID.isEmpty())
        return;

    if (command == QLatin1String("packets.details")) {
        if (data.value(QStringLiteral("packet_id")).toString() != side.packetID)
            return;
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        if (!sourceID.isEmpty() && !side.sourceID.isEmpty() && sourceID != side.sourceID)
            return;
        side.lines = diffDetailLines(data.value(QStringLiteral("nodes")).toList());
        side.detailsLoaded = true;
        side.error.clear();
        recomputeDetails();
    } else if (command == QLatin1String("packets.bytes")) {
        if (data.value(QStringLiteral("packet_id")).toString() != side.packetID)
            return;
        side.bytes = QByteArray::fromBase64(data.value(QStringLiteral("data")).toByteArray());
        side.bytesLoaded = true;
        side.error.clear();
        recomputeBytes();
    } else {
        return;
    }
    emit stateChanged();
}

void DiffController::handleFailure(Side &side, const QString &command, const QString &message)
{
    if (command != QLatin1String("packets.details") && command != QLatin1String("packets.bytes"))
        return;
    side.error = message;
    emit stateChanged();
}

void DiffController::recomputeDetails()
{
    m_sideBySideRows.clear();
    m_unifiedRows.clear();

    if (!m_left.detailsLoaded || !m_right.detailsLoaded) {
        rebuildChangeRows();
        emit rowsChanged();
        return;
    }

    const QVector<DiffLineEdit> edits = diffLines(m_left.lines, m_right.lines);

    m_unifiedRows.reserve(edits.size());
    for (const DiffLineEdit &edit : edits) {
        QVariantMap row;
        row.insert(QStringLiteral("marker"), QString(edit.marker));
        row.insert(QStringLiteral("text"), edit.text);
        row.insert(QStringLiteral("changed"), edit.marker != QLatin1Char(' '));
        m_unifiedRows.append(row);
    }

    int index = 0;
    while (index < edits.size()) {
        if (edits.at(index).marker == QLatin1Char(' ')) {
            QVariantMap row;
            row.insert(QStringLiteral("left"), edits.at(index).text);
            row.insert(QStringLiteral("right"), edits.at(index).text);
            row.insert(QStringLiteral("changed"), false);
            row.insert(QStringLiteral("leftEmpty"), false);
            row.insert(QStringLiteral("rightEmpty"), false);
            m_sideBySideRows.append(row);
            ++index;
            continue;
        }

        // Align a run of removals with the insertions that replaced them so
        // changed lines sit next to each other instead of in two blocks.
        QStringList removed;
        QStringList inserted;
        while (index < edits.size() && edits.at(index).marker != QLatin1Char(' ')) {
            if (edits.at(index).marker == QLatin1Char('-'))
                removed.append(edits.at(index).text);
            else
                inserted.append(edits.at(index).text);
            ++index;
        }
        const int rowCount = std::max(removed.size(), inserted.size());
        for (int row = 0; row < rowCount; ++row) {
            QVariantMap entry;
            entry.insert(QStringLiteral("left"),
                         row < removed.size() ? removed.at(row) : QString());
            entry.insert(QStringLiteral("right"),
                         row < inserted.size() ? inserted.at(row) : QString());
            entry.insert(QStringLiteral("leftEmpty"), row >= removed.size());
            entry.insert(QStringLiteral("rightEmpty"), row >= inserted.size());
            entry.insert(QStringLiteral("changed"), true);
            m_sideBySideRows.append(entry);
        }
    }

    rebuildChangeRows();
    emit rowsChanged();
}

void DiffController::recomputeBytes()
{
    m_byteRange = DiffByteRange();
    if (m_left.bytesLoaded && m_right.bytesLoaded)
        m_byteRange = diffBytes(m_left.bytes, m_right.bytes);
    emit bytesChanged();
}

void DiffController::rebuildChangeRows()
{
    m_changeRows.clear();
    const QVariantList &rows =
        m_displayMode == QLatin1String("unified") ? m_unifiedRows : m_sideBySideRows;
    for (int i = 0; i < rows.size(); ++i) {
        if (rows.at(i).toMap().value(QStringLiteral("changed")).toBool())
            m_changeRows.append(i);
    }
}

int DiffController::nextChangeRow(int currentRow, bool backwards) const
{
    if (m_changeRows.isEmpty())
        return -1;

    QVector<int> rows;
    rows.reserve(m_changeRows.size());
    for (const QVariant &value : m_changeRows)
        rows.append(value.toInt());

    if (backwards) {
        for (int i = rows.size() - 1; i >= 0; --i) {
            if (rows.at(i) < currentRow)
                return rows.at(i);
        }
        return rows.last();
    }
    for (int row : rows) {
        if (row > currentRow)
            return row;
    }
    return rows.first();
}
