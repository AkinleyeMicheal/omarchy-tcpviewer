#pragma once

#include "packetmodel.h"

#include <QElapsedTimer>
#include <QObject>
#include <QVector>
#include <QtQml/qqmlregistration.h>

class QQuickWindow;
class QTimer;

// Spike #2 harness: drives the packet table with a synthetic 10k pps stream and
// reports insert cost and rendered frame pacing. Enabled with TCPVIEWER_SPIKE=1;
// exits automatically after the run so it can be scripted.
class Benchmark : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool enabled READ enabled CONSTANT)
    Q_PROPERTY(QString view READ view CONSTANT)
    Q_PROPERTY(bool follow READ follow CONSTANT)

public:
    explicit Benchmark(QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    QString view() const { return m_view; }
    bool follow() const { return m_follow; }

    // Called from QML once the window is ready.
    Q_INVOKABLE void start(PacketListModel *model, QObject *windowObject);

private:
    void emitBatch();
    void finish();
    QVector<PacketRow> makeRows(int count);
    static qint64 residentBytes();

    bool m_enabled = false;
    QString m_view = QStringLiteral("table");
    bool m_follow = true;
    int m_pps = 10000;
    int m_seconds = 6;

    PacketListModel *m_model = nullptr;
    QTimer *m_timer = nullptr;
    QElapsedTimer m_runClock;
    QElapsedTimer m_frameClock;

    qint64 m_inserted = 0;
    qint64 m_batches = 0;
    qint64 m_insertTotalNs = 0;
    qint64 m_insertMaxNs = 0;

    qint64 m_frameCount = 0;
    qint64 m_lastFrameNs = -1;
    qint64 m_maxFrameGapNs = 0;
    QVector<qint64> m_frameGapsNs;

    quint32 m_randomState = 0x9e3779b9u;
    quint64 m_nextNumber = 1;
    qint64 m_startRss = 0;
};
