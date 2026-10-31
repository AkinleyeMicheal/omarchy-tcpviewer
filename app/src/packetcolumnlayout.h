#pragma once

#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>
#include <QtQml/qqmlregistration.h>

// Packet-table column catalog, visibility, widths, and user-created protocol
// field columns. Mirrors upstream PacketTableColumnService and
// PacketTableColumnLayoutStore. The layout is deliberately bounded: settings
// and custom field names are untrusted input and must not grow the table
// without limit.
class PacketColumnLayout : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantList columns READ columns NOTIFY columnsChanged)
    Q_PROPERTY(QVariantList menuEntries READ menuEntries NOTIFY columnsChanged)
    Q_PROPERTY(int visibleCount READ visibleCount NOTIFY columnsChanged)
    Q_PROPERTY(QVariantList customColumns READ customColumns NOTIFY customColumnsChanged)

public:
    explicit PacketColumnLayout(QObject *parent = nullptr, const QString &settingsFile = QString());

    QVariantList columns() const;
    QVariantList menuEntries() const;
    int visibleCount() const;
    QVariantList customColumns() const;

    Q_INVOKABLE bool toggleColumn(const QString &identifier);
    Q_INVOKABLE bool setColumnVisible(const QString &identifier, bool visible);
    // Visual reordering (upstream NSTableView column drag): visibleIndex is
    // the insertion slot among the other visible columns; the Comment column
    // stays pinned last and cannot be moved.
    Q_INVOKABLE bool moveColumn(const QString &identifier, int visibleIndex);
    Q_INVOKABLE void resetColumns();
    Q_INVOKABLE bool setColumnWidth(const QString &identifier, int width);
    Q_INVOKABLE int columnWidth(const QString &identifier) const;
    Q_INVOKABLE int columnMinimumWidth(const QString &identifier) const;
    Q_INVOKABLE void resetColumnWidth(const QString &identifier);
    Q_INVOKABLE QString createCustomColumn(const QString &fieldName, const QString &title);
    Q_INVOKABLE bool removeCustomColumn(const QString &identifier);
    Q_INVOKABLE QString fieldForColumn(const QString &identifier) const;

signals:
    void columnsChanged();
    void customColumnsChanged();

private:
    struct Definition {
        QString identifier;
        QString title;
        QString role;
        QString fieldName;
        int defaultWidth = 100;
        int minimumWidth = 50;
        bool defaultVisible = true;
        bool canHide = true;
        bool custom = false;
    };

    static QVector<Definition> defaultDefinitions();
    static QString normalizedFieldName(const QString &fieldName);
    static QString identifierForField(const QString &normalizedField);
    static QString sanitizedTitle(const QString &title, const QString &fallback);
    static int clampedWidth(int width, int minimum);

    int indexOf(const QString &identifier) const;
    bool isVisible(const QString &identifier) const;
    int visibleCountInternal() const;
    void load();
    void save() const;
    void emitChanged();
    void rebuildOrder(const QStringList &loadedOrder);

    QVector<Definition> m_definitions;
    QStringList m_order;
    QHash<QString, bool> m_visibility;
    QHash<QString, int> m_widths;
    QString m_settingsFile;
};
