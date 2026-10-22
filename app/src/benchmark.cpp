#include "benchmark.h"
#include "packetmodel.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QTimer>
#include <algorithm>

namespace {

const char *const kProtocols[] = {"TCP", "TLS", "DNS", "UDP", "HTTP", "ARP", "QUIC"};
const char *const kClients[] = {"Firefox", "curl", "Slack", "Spotify", "systemd-resolved", "Kitty", "Code"};
const char *const kDomains[] = {"example.com", "api.github.com", "static.spotify.com", "registry.npmjs.org", "1.1.1.1", ""};

} // namespace

Benchmark::Benchmark(QObject *parent)
    : QObject(parent)
{
    m_enabled = qEnvironmentVariableIsSet("TCPVIEWER_SPIKE");
    const QString view = qEnvironmentVariable("TCPVIEWER_SPIKE_VIEW");
    if (view == QStringLiteral("table") || view == QStringLiteral("list"))
        m_view = view;
    const QString follow = qEnvironmentVariable("TCPVIEWER_SPIKE_FOLLOW");
    if (follow == QStringLiteral("0"))
        m_follow = false;

    bool ok = false;
    const int pps = qEnvironmentVariableIntValue("TCPVIEWER_SPIKE_PPS", &ok);
    if (ok && pps > 0)
        m_pps = pps;
    const int seconds = qEnvironmentVariableIntValue("TCPVIEWER_SPIKE_SECONDS", &ok);
    if (ok && seconds > 0)
        m_seconds = seconds;
}

void Benchmark::start(PacketListModel *model, QObject *windowObject)
{
    if (!m_enabled || m_model || !model)
        return;

    auto *window = qobject_cast<QQuickWindow *>(windowObject);
    if (!window) {
        qWarning("BENCH: no QQuickWindow; nothing to measure");
        QCoreApplication::quit();
        return;
    }

    m_model = model;
    m_startRss = residentBytes();
    m_runClock.start();
    m_frameClock.start();

    connect(window, &QQuickWindow::frameSwapped, this, [this]() {
        const qint64 now = m_frameClock.nsecsElapsed();
        ++m_frameCount;
        if (m_lastFrameNs >= 0) {
            const qint64 gap = now - m_lastFrameNs;
            m_frameGapsNs.append(gap);
            m_maxFrameGapNs = std::max(m_maxFrameGapNs, gap);
        }
        m_lastFrameNs = now;
    });

    // ~60 Hz producer cadence, matching the daemon's packet event batching.
    m_timer = new QTimer(this);
    m_timer->setTimerType(Qt::PreciseTimer);
    m_timer->setInterval(16);
    connect(m_timer, &QTimer::timeout, this, &Benchmark::emitBatch);
    m_timer->start();

    QTimer::singleShot(m_seconds * 1000, this, &Benchmark::finish);
}

QVector<PacketRow> Benchmark::makeRows(int count)
{
    QVector<PacketRow> rows;
    rows.reserve(count);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < count; ++i) {
        // Deterministic xorshift so runs are comparable.
        m_randomState ^= m_randomState << 13;
        m_randomState ^= m_randomState >> 17;
        m_randomState ^= m_randomState << 5;
        const quint32 random = m_randomState;

        PacketRow row;
        row.number = m_nextNumber++;
        row.timeText = now.addMSecs(i).toString(QStringLiteral("HH:mm:ss.zzz"));
        row.source = QStringLiteral("192.168.88.%1").arg(2 + (random % 250));
        row.destination = QStringLiteral("172.65.90.%1").arg(2 + ((random >> 8) % 250));
        row.sourcePort = QString::number(1024 + (random % 64000));
        row.destinationPort = QString::number((random % 2) ? 443 : 53);
        row.protocol = QString::fromLatin1(kProtocols[random % 7]);
        row.client = QString::fromLatin1(kClients[(random >> 4) % 7]);
        row.domain = QString::fromLatin1(kDomains[(random >> 12) % 6]);
        row.streamId = QStringLiteral("tcp:%1").arg(random % 2000);
        row.length = 40 + int((random >> 16) % 1400);
        row.severity = ((random >> 20) % 50 == 0) ? 1 : 0;
        row.summary = QStringLiteral("%1 → %2 Len=%3")
                          .arg(row.sourcePort, row.destinationPort)
                          .arg(row.length);
        rows.append(row);
    }
    return rows;
}

void Benchmark::emitBatch()
{
    if (!m_model)
        return;

    const qint64 elapsedMs = m_runClock.elapsed();
    const qint64 targetRows = (qint64(m_pps) * elapsedMs) / 1000;
    qint64 pending = targetRows - m_inserted;
    if (pending <= 0)
        return;
    // A stalled frame shouldn't turn into an unbounded catch-up burst.
    pending = std::min<qint64>(pending, 4000);

    QElapsedTimer insertClock;
    insertClock.start();
    m_model->appendRows(makeRows(int(pending)));
    const qint64 ns = insertClock.nsecsElapsed();

    m_inserted += pending;
    ++m_batches;
    m_insertTotalNs += ns;
    m_insertMaxNs = std::max(m_insertMaxNs, ns);
}

void Benchmark::finish()
{
    if (!m_model)
        return;
    m_timer->stop();

    std::sort(m_frameGapsNs.begin(), m_frameGapsNs.end());
    const auto percentile = [this](double fraction) -> double {
        if (m_frameGapsNs.isEmpty())
            return 0.0;
        const int index = std::clamp(int(m_frameGapsNs.size() * fraction), 0, int(m_frameGapsNs.size()) - 1);
        return double(m_frameGapsNs.at(index)) / 1e6;
    };

    const double elapsedSeconds = double(m_runClock.elapsed()) / 1000.0;
    const double avgFps = elapsedSeconds > 0 ? double(m_frameCount) / elapsedSeconds : 0.0;
    const qint64 endRss = residentBytes();

    QJsonObject result;
    result["view"] = m_view;
    result["follow"] = m_follow;
    result["seconds"] = elapsedSeconds;
    result["target_pps"] = m_pps;
    result["rows"] = double(m_inserted);
    result["batches"] = double(m_batches);
    result["insert_avg_ms"] = m_batches > 0 ? double(m_insertTotalNs) / double(m_batches) / 1e6 : 0.0;
    result["insert_max_ms"] = double(m_insertMaxNs) / 1e6;
    result["frames"] = double(m_frameCount);
    result["avg_fps"] = avgFps;
    result["frame_p50_ms"] = percentile(0.50);
    result["frame_p99_ms"] = percentile(0.99);
    result["frame_max_ms"] = double(m_maxFrameGapNs) / 1e6;
    result["rss_start_mb"] = double(m_startRss) / (1024.0 * 1024.0);
    result["rss_end_mb"] = double(endRss) / (1024.0 * 1024.0);

    const QJsonDocument document(result);
    const QByteArray line = "BENCH:" + document.toJson(QJsonDocument::Compact);
    qInfo().noquote() << QString::fromUtf8(line);
    // Redirection through tooling can swallow Qt's stderr sink; mirror to a file
    // when the harness asks for one.
    const QString outPath = qEnvironmentVariable("TCPVIEWER_SPIKE_OUT");
    if (!outPath.isEmpty()) {
        QFile out(outPath);
        if (out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            out.write(line);
            out.write("\n");
        }
    }

    m_model = nullptr;
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
}

qint64 Benchmark::residentBytes()
{
    QFile status(QStringLiteral("/proc/self/status"));
    if (!status.open(QIODevice::ReadOnly))
        return 0;
    // /proc files report size 0, so QFile::atEnd() is unreliable; parse the
    // whole read instead of the streaming loop.
    const QByteArray contents = status.readAll();
    const qsizetype start = contents.indexOf("VmRSS:");
    if (start < 0)
        return 0;
    const qsizetype end = contents.indexOf('\n', start);
    const QByteArray line = contents.mid(start, end < 0 ? -1 : end - start);
    const QList<QByteArray> parts = line.simplified().split(' ');
    if (parts.size() < 2)
        return 0;
    return parts.at(1).toLongLong() * 1024;
}
