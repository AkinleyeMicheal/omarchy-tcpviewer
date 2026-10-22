#pragma once

#include <QByteArray>
#include <QColor>
#include <QQuickPaintedItem>
#include <QtQml/qqmlregistration.h>

// Painted hex/ASCII dump (upstream embeds HexFiend). Painting keeps the byte
// range highlight cheap and avoids one QML item per byte.
class HexView : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QByteArray bytes READ bytes WRITE setBytes NOTIFY bytesChanged)
    Q_PROPERTY(int highlightOffset READ highlightOffset WRITE setHighlightOffset NOTIFY highlightChanged)
    Q_PROPERTY(int highlightLength READ highlightLength WRITE setHighlightLength NOTIFY highlightChanged)
    Q_PROPERTY(QString fontFamily READ fontFamily WRITE setFontFamily NOTIFY fontChanged)
    Q_PROPERTY(int pixelSize READ pixelSize WRITE setPixelSize NOTIFY fontChanged)
    Q_PROPERTY(QColor textColor READ textColor WRITE setTextColor NOTIFY colorsChanged)
    Q_PROPERTY(QColor secondaryTextColor READ secondaryTextColor WRITE setSecondaryTextColor NOTIFY colorsChanged)
    Q_PROPERTY(QColor highlightColor READ highlightColor WRITE setHighlightColor NOTIFY colorsChanged)
    Q_PROPERTY(QColor backgroundColor READ backgroundColor WRITE setBackgroundColor NOTIFY colorsChanged)

public:
    explicit HexView(QQuickItem *parent = nullptr);

    void paint(QPainter *painter) override;
    void wheelEvent(QWheelEvent *event) override;

    QByteArray bytes() const { return m_bytes; }
    void setBytes(const QByteArray &bytes);
    int highlightOffset() const { return m_highlightOffset; }
    void setHighlightOffset(int offset);
    int highlightLength() const { return m_highlightLength; }
    void setHighlightLength(int length);
    QString fontFamily() const { return m_fontFamily; }
    void setFontFamily(const QString &family);
    int pixelSize() const { return m_pixelSize; }
    void setPixelSize(int size);
    QColor textColor() const { return m_textColor; }
    void setTextColor(const QColor &color);
    QColor secondaryTextColor() const { return m_secondaryTextColor; }
    void setSecondaryTextColor(const QColor &color);
    QColor highlightColor() const { return m_highlightColor; }
    void setHighlightColor(const QColor &color);
    QColor backgroundColor() const { return m_backgroundColor; }
    void setBackgroundColor(const QColor &color);

signals:
    void bytesChanged();
    void highlightChanged();
    void fontChanged();
    void colorsChanged();

private:
    static constexpr int groupSize = 8;
    int bytesPerRow = 16; // Updated by paint() when the pane is too narrow.
    qreal rowHeight() const;
    qreal maximumScroll() const;
    void clampScroll();
    void ensureHighlightVisible();

    QByteArray m_bytes;
    int m_highlightOffset = -1;
    int m_highlightLength = 0;
    QString m_fontFamily = QStringLiteral("JetBrainsMono Nerd Font");
    int m_pixelSize = 11;
    qreal m_scrollY = 0;
    QColor m_textColor = QColor(235, 235, 245);
    QColor m_secondaryTextColor = QColor(140, 140, 150);
    QColor m_highlightColor = QColor(10, 132, 255, 80);
    QColor m_backgroundColor = Qt::transparent;
};
