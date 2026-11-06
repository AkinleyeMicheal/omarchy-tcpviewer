#include "hexview.h"

#include <QFontMetricsF>
#include <QPainter>
#include <QWheelEvent>

#include <algorithm>
#include <cmath>

HexView::HexView(QQuickItem *parent)
    : QQuickPaintedItem(parent)
{
    setAcceptedMouseButtons(Qt::NoButton);
    setOpaquePainting(false);
}

void HexView::setBytes(const QByteArray &bytes)
{
    if (bytes == m_bytes)
        return;
    m_bytes = bytes;
    m_scrollY = 0;
    emit bytesChanged();
    update();
}

void HexView::setHighlightOffset(int offset)
{
    offset = qMax(-1, offset);
    if (offset == m_highlightOffset)
        return;
    m_highlightOffset = offset;
    ensureHighlightVisible();
    emit highlightChanged();
    update();
}

void HexView::setHighlightLength(int length)
{
    length = qMax(0, length);
    if (length == m_highlightLength)
        return;
    m_highlightLength = length;
    ensureHighlightVisible();
    emit highlightChanged();
    update();
}

QVariantList HexView::highlights() const
{
    QVariantList list;
    list.reserve(m_highlights.size());
    for (const auto &range : m_highlights) {
        QVariantMap entry;
        entry.insert(QStringLiteral("offset"), range.first);
        entry.insert(QStringLiteral("length"), range.second);
        list.append(entry);
    }
    return list;
}

void HexView::setHighlights(const QVariantList &highlights)
{
    QVector<QPair<int, int>> ranges;
    ranges.reserve(highlights.size());
    for (const QVariant &value : highlights) {
        const QVariantMap entry = value.toMap();
        const int offset = entry.value(QStringLiteral("offset")).toInt();
        const int length = qMax(0, entry.value(QStringLiteral("length")).toInt());
        if (offset < 0 || length == 0)
            continue;
        ranges.append({offset, length});
    }
    if (ranges == m_highlights)
        return;
    m_highlights = ranges;
    ensureHighlightVisible();
    emit highlightChanged();
    update();
}

void HexView::setSelectionOffset(int offset)
{
    offset = qMax(-1, offset);
    if (offset == m_selectionOffset)
        return;
    m_selectionOffset = offset;
    ensureOffsetVisible(m_selectionOffset);
    emit selectionChanged();
    update();
}

void HexView::setSelectionLength(int length)
{
    length = qMax(0, length);
    if (length == m_selectionLength)
        return;
    m_selectionLength = length;
    ensureOffsetVisible(m_selectionOffset);
    emit selectionChanged();
    update();
}

void HexView::select(int offset, int length)
{
    if (offset == m_selectionOffset && length == m_selectionLength) {
        ensureOffsetVisible(offset);
        update();
        return;
    }
    m_selectionOffset = qMax(-1, offset);
    m_selectionLength = qMax(0, length);
    ensureOffsetVisible(m_selectionOffset);
    emit selectionChanged();
    update();
}

void HexView::setFontFamily(const QString &family)
{
    if (family == m_fontFamily)
        return;
    m_fontFamily = family;
    emit fontChanged();
    update();
}

void HexView::setPixelSize(int size)
{
    size = qBound(8, size, 24);
    if (size == m_pixelSize)
        return;
    m_pixelSize = size;
    emit fontChanged();
    update();
}

void HexView::setTextColor(const QColor &color)
{
    if (color == m_textColor)
        return;
    m_textColor = color;
    emit colorsChanged();
    update();
}

void HexView::setSecondaryTextColor(const QColor &color)
{
    if (color == m_secondaryTextColor)
        return;
    m_secondaryTextColor = color;
    emit colorsChanged();
    update();
}

void HexView::setHighlightColor(const QColor &color)
{
    if (color == m_highlightColor)
        return;
    m_highlightColor = color;
    emit colorsChanged();
    update();
}

void HexView::setSelectionColor(const QColor &color)
{
    if (color == m_selectionColor)
        return;
    m_selectionColor = color;
    emit colorsChanged();
    update();
}

void HexView::setBackgroundColor(const QColor &color)
{
    if (color == m_backgroundColor)
        return;
    m_backgroundColor = color;
    emit colorsChanged();
    update();
}

qreal HexView::rowHeight() const
{
    QFont font(m_fontFamily);
    font.setPixelSize(m_pixelSize);
    font.setStyleHint(QFont::Monospace);
    return std::max<qreal>(13.0, QFontMetricsF(font).height() + 1.0);
}

qreal HexView::maximumScroll() const
{
    const int rows = (m_bytes.size() + bytesPerRow - 1) / bytesPerRow;
    const qreal content = rows * rowHeight() + 12.0;
    return std::max<qreal>(0.0, content - height());
}

void HexView::clampScroll()
{
    m_scrollY = std::clamp(m_scrollY, 0.0, maximumScroll());
}

void HexView::ensureOffsetVisible(int offset)
{
    if (offset < 0 || height() <= 0)
        return;
    const qreal lineHeight = rowHeight();
    const int row = offset / bytesPerRow;
    const qreal top = 6.0 + row * lineHeight;
    const qreal bottom = top + lineHeight;
    if (top < m_scrollY)
        m_scrollY = top;
    else if (bottom > m_scrollY + height())
        m_scrollY = bottom - height();
    clampScroll();
}

void HexView::ensureHighlightVisible()
{
    ensureOffsetVisible(m_highlightOffset);
}

void HexView::wheelEvent(QWheelEvent *event)
{
    const qreal delta = event->angleDelta().y();
    if (delta == 0) {
        QQuickPaintedItem::wheelEvent(event);
        return;
    }
    m_scrollY -= (delta / 120.0) * rowHeight() * 3.0;
    clampScroll();
    update();
    event->accept();
}

void HexView::paint(QPainter *painter)
{
    if (m_backgroundColor.alpha() > 0)
        painter->fillRect(boundingRect(), m_backgroundColor);

    if (m_bytes.isEmpty()) {
        QFont font(m_fontFamily);
        font.setPixelSize(m_pixelSize);
        painter->setFont(font);
        painter->setPen(m_secondaryTextColor);
        painter->drawText(boundingRect(), Qt::AlignCenter, QStringLiteral("No bytes"));
        return;
    }

    QFont font(m_fontFamily);
    font.setPixelSize(m_pixelSize);
    font.setStyleHint(QFont::Monospace);
    font.setFixedPitch(true);
    painter->setFont(font);
    painter->setRenderHint(QPainter::TextAntialiasing, true);

    const QFontMetricsF metrics(font);
    const qreal charWidth = std::max<qreal>(1.0, metrics.horizontalAdvance(QLatin1Char('0')));
    const qreal lineHeight = rowHeight();
    const qreal left = 8.0;
    const qreal hexX = left + 8.0 * charWidth + 10.0;
    const qreal groupGap = charWidth;

    // Shrink to one 8-byte group so the ASCII pane still fits at inspector widths.
    const int sixteenWidth = hexX + (16 * 3 + 1) * charWidth + groupGap + 16 * charWidth + 8.0;
    bytesPerRow = width() >= sixteenWidth ? 16 : 8;
    const qreal asciiX = hexX + (bytesPerRow * 3.0 + 1.0) * charWidth + groupGap;

    clampScroll();

    const int firstRow = std::max(0, static_cast<int>(std::floor(m_scrollY / lineHeight)) - 1);
    const int lastDataRow = static_cast<int>((m_bytes.size() + bytesPerRow - 1) / bytesPerRow) - 1;
    const int lastRow = std::min(lastDataRow,
        static_cast<int>(std::ceil((m_scrollY + height()) / lineHeight)) + 1
    );

    for (int row = firstRow; row <= lastRow; ++row) {
        const qreal y = 6.0 + row * lineHeight - m_scrollY;
        if (y + lineHeight < 0 || y > height())
            continue;

        const int base = row * bytesPerRow;
        const int rowBytes = std::min(bytesPerRow, static_cast<int>(m_bytes.size() - base));

        painter->setPen(m_secondaryTextColor);
        painter->drawText(QPointF(left, y + metrics.ascent()), QStringLiteral("%1")
            .arg(base, 8, 16, QLatin1Char('0')).toUpper());

        QString hexLine;
        QString asciiLine;
        hexLine.reserve(bytesPerRow * 3 + 1);
        asciiLine.reserve(bytesPerRow);
        for (int i = 0; i < bytesPerRow; ++i) {
            if (i == groupSize)
                hexLine.append(QLatin1Char(' '));
            if (i < rowBytes) {
                const unsigned char value = static_cast<unsigned char>(m_bytes.at(base + i));
                hexLine.append(QStringLiteral("%1 ").arg(value, 2, 16, QLatin1Char('0')).toUpper());
                asciiLine.append(value >= 0x20 && value <= 0x7e ? QLatin1Char(static_cast<char>(value))
                                                                : QLatin1Char('.'));
            } else {
                hexLine.append(QStringLiteral("   "));
                asciiLine.append(QLatin1Char(' '));
            }
        }

        const qreal textY = y + metrics.ascent();
        painter->setPen(m_textColor);
        painter->drawText(QPointF(hexX, textY), hexLine);
        painter->setPen(m_secondaryTextColor);
        painter->drawText(QPointF(asciiX, textY), asciiLine);

        // Diff tint over every changed range, then the stronger selection
        // (current change or search match) on top; text is redrawn for
        // covered bytes so it stays legible over both fills.
        QVector<QPair<int, int>> ranges = m_highlights;
        if (m_highlightOffset >= 0 && m_highlightLength > 0)
            ranges.append({m_highlightOffset, m_highlightLength});
        if (!ranges.isEmpty() || (m_selectionOffset >= 0 && m_selectionLength > 0)) {
            auto covered = [base, rowBytes](const QVector<QPair<int, int>> &list, int index) {
                for (const auto &range : list) {
                    if (index >= range.first && index < range.first + range.second)
                        return true;
                }
                return false;
            };
            QVector<QPair<int, int>> selection;
            if (m_selectionOffset >= 0 && m_selectionLength > 0)
                selection.append({m_selectionOffset, m_selectionLength});

            painter->setPen(Qt::NoPen);
            painter->setBrush(m_highlightColor);
            for (const auto &range : ranges) {
                for (int i = 0; i < rowBytes; ++i) {
                    const int index = base + i;
                    if (index < range.first || index >= range.first + range.second)
                        continue;
                    const qreal byteX = hexX + i * 3.0 * charWidth + (i >= groupSize ? groupGap : 0.0);
                    painter->drawRect(QRectF(byteX - 1.0, y + 1.0, charWidth * 2.0 + 1.0, lineHeight - 2.0));
                    painter->drawRect(QRectF(asciiX + i * charWidth, y + 1.0, charWidth, lineHeight - 2.0));
                }
            }
            painter->setBrush(m_selectionColor);
            for (const auto &range : selection) {
                for (int i = 0; i < rowBytes; ++i) {
                    const int index = base + i;
                    if (index < range.first || index >= range.first + range.second)
                        continue;
                    const qreal byteX = hexX + i * 3.0 * charWidth + (i >= groupSize ? groupGap : 0.0);
                    painter->drawRect(QRectF(byteX - 1.0, y + 1.0, charWidth * 2.0 + 1.0, lineHeight - 2.0));
                    painter->drawRect(QRectF(asciiX + i * charWidth, y + 1.0, charWidth, lineHeight - 2.0));
                }
            }
            painter->setPen(m_textColor);
            for (int i = 0; i < rowBytes; ++i) {
                const int index = base + i;
                if (!covered(ranges, index) && !covered(selection, index))
                    continue;
                const qreal byteX = hexX + i * 3.0 * charWidth + (i >= groupSize ? groupGap : 0.0);
                const unsigned char value = static_cast<unsigned char>(m_bytes.at(index));
                painter->drawText(QPointF(byteX, textY),
                                  QStringLiteral("%1").arg(value, 2, 16, QLatin1Char('0')).toUpper());
                painter->drawText(QPointF(asciiX + i * charWidth, textY),
                                  QChar(value >= 0x20 && value <= 0x7e ? static_cast<char>(value) : '.'));
            }
        }
    }

    const qreal maxScroll = maximumScroll();
    if (maxScroll > 0) {
        const qreal trackTop = 4.0;
        const qreal trackHeight = height() - 8.0;
        const qreal thumbHeight = std::max<qreal>(24.0, trackHeight * height() / (height() + maxScroll));
        const qreal thumbTop = trackTop + (trackHeight - thumbHeight) * (m_scrollY / maxScroll);
        painter->setPen(Qt::NoPen);
        painter->setBrush(QColor(m_secondaryTextColor.red(), m_secondaryTextColor.green(),
                                 m_secondaryTextColor.blue(), 70));
        painter->drawRoundedRect(QRectF(width() - 6.0, thumbTop, 3.0, thumbHeight), 1.5, 1.5);
    }
}
