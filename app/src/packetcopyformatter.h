#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// Copy-row formats for the packet table (upstream
// PacketTableCopyFormatter + PacketTableContextMenuController). The column
// set is fixed and independent of the visible/reordered table columns.
class PacketCopyFormatter : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit PacketCopyFormatter(QObject *parent = nullptr);

    struct CopyColumn
    {
        const char *mapKey;
        const char *jsonKey;
        const char *title;
    };

    // rows: PacketRow maps (packetRowToMap shape). format: plainText, json,
    // markdownTable, csv, csvWithHeader — csv is the upstream default.
    Q_INVOKABLE QString rows(const QVariantList &rows, const QString &format) const;

    // Copy Cell Value: one value per target row, newline-separated.
    Q_INVOKABLE QString cells(const QStringList &values) const;

    // Display text for one table column in the packetRowToMap shape —
    // the same mapping PacketTableView uses to render cells; custom
    // columns come through customValue (resolved by the caller).
    Q_INVOKABLE QString cellFor(const QVariantMap &row, const QVariantMap &column,
                                const QVariant &customValue) const;

private:
    QString cellText(const QVariantMap &row, const CopyColumn &column) const;
    QString plainTextEscaped(QString value) const;
    // Tab-separated rows for lightweight plain-text pasting.
    QString plainTextRows(const QVariantList &rows) const;
    // Pretty JSON array with stable string-typed packet fields.
    QString jsonRows(const QVariantList &rows) const;
    // GitHub-flavored Markdown table with escaped cell separators.
    QString markdownTableRows(const QVariantList &rows) const;
    QString csvEscaped(QString value) const;
    QString csvRows(const QVariantList &rows) const;
    QString csvRowsWithHeader(const QVariantList &rows) const;

    static const CopyColumn *copyColumns();
    static constexpr int copyColumnCount = 10;
};
