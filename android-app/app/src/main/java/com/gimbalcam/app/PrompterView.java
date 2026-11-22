package com.gimbalcam.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.View;

/** 悬浮提词框：可拖动、右下角缩放、匀速上滚、镜像、可隐藏边框 */
public class PrompterView extends View {

    private Paint bg, textPaint, borderPaint, handlePaint;
    private String text = "";
    private String[] lines = new String[0];
    private float scrollY = 0;
    private float speed = 1.0f;       // 像素/帧基准
    private float fontSize = 28f;
    private boolean playing = false;
    private boolean mirrored = false;
    private boolean showBorder = true;
    private boolean followLine = true;

    private RectF box = new RectF(40, 200, 700, 520);
    private RectF handle = new RectF();
    private int dragMode = 0;  // 1=移动 2=缩放
    private float lastX, lastY;

    public PrompterView(Context c) { super(c); init(); }
    public PrompterView(Context c, AttributeSet a) { super(c, a); init(); }

    private void init() {
        bg = new Paint(Paint.ANTI_ALIAS_FLAG);
        bg.setColor(Color.argb(150, 0, 0, 0));
        textPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        textPaint.setColor(Color.WHITE);
        textPaint.setTextSize(fontSize);
        textPaint.setTextAlign(Paint.Align.LEFT);
        borderPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        borderPaint.setColor(Color.WHITE);
        borderPaint.setStyle(Paint.Style.STROKE);
        borderPaint.setStrokeWidth(2);
        handlePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        handlePaint.setColor(Color.WHITE);
        handlePaint.setStyle(Paint.Style.FILL);
        setText("在此输入台词，或点上方「台词」粘贴稿子。\n点「播放」开始自动滚动词。");
    }

    public void setText(String t) {
        text = t == null ? "" : t;
        lines = text.split("\n");
        scrollY = 0;
        invalidate();
    }
    public void setPlaying(boolean p) { playing = p; invalidate(); }
    public void setSpeed(float s) { speed = s; }
    public void setFontSize(float s) { fontSize = s; textPaint.setTextSize(fontSize); invalidate(); }
    public void setMirrored(boolean m) { mirrored = m; invalidate(); }
    public void setShowBorder(boolean s) { showBorder = s; invalidate(); }
    public void setFollowLine(boolean f) { followLine = f; invalidate(); }
    public void resetScroll() { scrollY = 0; invalidate(); }
    public boolean isPlaying() { return playing; }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        canvas.drawRoundRect(box, 16, 16, bg);
        if (showBorder) {
            canvas.drawRoundRect(box, 16, 16, borderPaint);
            if (followLine) {
                float midY = box.top + box.height() / 2;
                canvas.drawLine(box.left + 8, midY, box.right - 8, midY, borderPaint);
            }
        }
        // 提词文本
        canvas.save();
        canvas.clipRect(box.left + 12, box.top + 8, box.right - 12, box.bottom - 8);
        if (mirrored) {
            canvas.translate(box.left + box.right, 0);
            canvas.scale(-1, 1);
        }
        float y = box.top + 40 - scrollY;
        for (String line : lines) {
            canvas.drawText(line, box.left + 16, y, textPaint);
            y += fontSize * 1.5f;
        }
        canvas.restore();

        // 缩放手柄
        handle.set(box.right - 34, box.bottom - 34, box.right - 6, box.bottom - 6);
        canvas.drawRoundRect(handle, 6, 6, handlePaint);

        if (playing) {
            scrollY += speed;
            postInvalidateOnAnimation();
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        float x = e.getX(), y = e.getY();
        switch (e.getAction()) {
            case MotionEvent.ACTION_DOWN:
                if (handle.contains(x, y)) dragMode = 2;
                else if (box.contains(x, y)) dragMode = 1;
                else dragMode = 0;
                lastX = x; lastY = y;
                return dragMode != 0;
            case MotionEvent.ACTION_MOVE:
                float dx = x - lastX, dy = y - lastY;
                if (dragMode == 1) {
                    box.offset(dx, dy);
                } else if (dragMode == 2) {
                    box.right = Math.max(box.left + 160, box.right + dx);
                    box.bottom = Math.max(box.top + 100, box.bottom + dy);
                    box.right = Math.min(box.right, getWidth() - 8);
                    box.bottom = Math.min(box.bottom, getHeight() - 8);
                }
                lastX = x; lastY = y;
                invalidate();
                return true;
            case MotionEvent.ACTION_UP:
                dragMode = 0;
                return true;
        }
        return super.onTouchEvent(e);
    }
}
