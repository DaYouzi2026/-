package com.gimbalcam.app;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.camera.core.*;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.face.Face;
import com.google.mlkit.vision.face.FaceDetection;
import com.google.mlkit.vision.face.FaceDetector;
import com.google.mlkit.vision.face.FaceDetectorOptions;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends AppCompatActivity {

    private PreviewView previewView;
    private PrompterView prompter;
    private TextView statusText, logText;
    private BleController ble;
    private FollowEngine follow = new FollowEngine();
    private FaceDetector faceDetector;
    private ExecutorService cameraExecutor;

    // 设置面板
    private SeekBar sbGain, sbDeadzone, sbSmooth, sbSpeed, sbFont;
    private Switch swFollow, swMirror, swBorder, swInvertX, swInvertY;
    private Spinner spChannel, spInnerCs, spOuterCrc;
    private EditText etScript;

    private boolean showPrompter = true;
    private static final int REQ_PERMS = 100;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (!allPerms()) {
            ActivityCompat.requestPermissions(this, new String[]{
                    Manifest.permission.CAMERA,
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_ADMIN,
                    Manifest.permission.ACCESS_FINE_LOCATION
            }, REQ_PERMS);
        }
        buildUI();
        ble = new BleController(this, new BleController.Listener() {
            public void onState(String s) { runOnUiThread(() -> statusText.setText(s)); }
            public void onDevices(List<android.bluetooth.BluetoothDevice> ds) { runOnUiThread(() -> updateDevices(ds)); }
            public void onLog(String l) { runOnUiThread(() -> appendLog(l)); }
        });
        faceDetector = FaceDetection.getClient(new FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setTrackingEnabled(true)
                .build());
        cameraExecutor = Executors.newSingleThreadExecutor();
        if (allPerms()) { startCamera(); ble.scan(); }
    }

    private boolean allPerms() {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                && ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] p, int[] r) {
        super.onRequestPermissionsResult(req, p, r);
        if (req == REQ_PERMS && allPerms()) { startCamera(); ble.scan(); }
    }

    // ---------------- UI ----------------
    private LinearLayout deviceList;
    private void buildUI() {
        FrameLayout root = new FrameLayout(this);

        previewView = new PreviewView(this);
        root.addView(previewView, new FrameLayout.LayoutParams(-1, -1));

        prompter = new PrompterView(this);
        root.addView(prompter, new FrameLayout.LayoutParams(-1, -1));

        // 顶部状态
        statusText = new TextView(this);
        statusText.setText("云台控制 · 初始化");
        statusText.setTextColor(0xFFFFFFFF);
        statusText.setBackgroundColor(0xAA000000);
        statusText.setPadding(16, 12, 16, 12);
        FrameLayout.LayoutParams stLp = new FrameLayout.LayoutParams(-2, -2);
        stLp.gravity = android.view.Gravity.TOP | android.view.Gravity.CENTER_HORIZONTAL;
        root.addView(statusText, stLp);

        // 顶部按钮行
        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setPadding(12, 60, 12, 8);
        top.addView(btn("扫描云台", v -> ble.scan()));
        top.addView(btn("跟随开/关", v -> {
            follow.enabled = !follow.enabled; follow.reset();
            toast(follow.enabled ? "跟随已开" : "跟随已关");
        }));
        top.addView(btn("提词器", v -> {
            showPrompter = !showPrompter;
            prompter.setVisibility(showPrompter ? View.VISIBLE : View.GONE);
        }));
        top.addView(btn("播放", v -> prompter.setPlaying(!prompter.isPlaying())));
        top.addView(btn("设置", v -> toggleSettings()));
        FrameLayout.LayoutParams topLp = new FrameLayout.LayoutParams(-1, -2);
        topLp.gravity = android.view.Gravity.TOP;
        root.addView(top, topLp);

        // 手动方向控制（真机验证协议用）
        LinearLayout dpad = new LinearLayout(this);
        dpad.setOrientation(LinearLayout.VERTICAL);
        dpad.setPadding(12, 0, 0, 0);
        LinearLayout row1 = new LinearLayout(this);
        row1.addView(btn("◀ 左", v -> sendTurn(-300, 0)));
        row1.addView(btn("停止", v -> sendTurn(0, 0)));
        row1.addView(btn("右 ▶", v -> sendTurn(300, 0)));
        dpad.addView(row1);
        LinearLayout row2 = new LinearLayout(this);
        row2.addView(btn("▲ 上", v -> sendTurn(0, 300)));
        row2.addView(btn("下 ▼", v -> sendTurn(0, -300)));
        dpad.addView(row2);
        FrameLayout.LayoutParams dLp = new FrameLayout.LayoutParams(-2, -2);
        dLp.gravity = android.view.Gravity.BOTTOM | android.view.Gravity.START;
        root.addView(dpad, dLp);

        // 日志（左下小窗）
        logText = new TextView(this);
        logText.setTextColor(0xFF00FF88);
        logText.setTextSize(10);
        logText.setBackgroundColor(0x88000000);
        logText.setMaxLines(6);
        FrameLayout.LayoutParams logLp = new FrameLayout.LayoutParams(500, -2);
        logLp.gravity = android.view.Gravity.BOTTOM | android.view.Gravity.END;
        root.addView(logText, logLp);

        // 设备列表（顶部下方，横向）
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        deviceList.setBackgroundColor(0xCC000000);
        FrameLayout.LayoutParams devLp = new FrameLayout.LayoutParams(-1, -2);
        devLp.gravity = android.view.Gravity.TOP;
        devLp.topMargin = 120;
        root.addView(deviceList, devLp);

        // 设置面板（默认隐藏）
        settingsPanel = buildSettings();
        settingsPanel.setVisibility(View.GONE);
        FrameLayout.LayoutParams setLp = new FrameLayout.LayoutParams(-1, -2);
        setLp.gravity = android.view.Gravity.BOTTOM;
        root.addView(settingsPanel, setLp);

        setContentView(root);
    }

    private LinearLayout settingsPanel;
    private LinearLayout buildSettings() {
        LinearLayout p = new LinearLayout(this);
        p.setOrientation(LinearLayout.VERTICAL);
        p.setBackgroundColor(0xEE111111);
        p.setPadding(20, 20, 20, 20);

        p.addView(label("跟随灵敏度（越大越灵敏）"));
        sbGain = seek(1, 300, (int)(follow.gain*100), v -> follow.gain = v/100f);
        p.addView(sbGain);

        p.addView(label("死区（越大越稳，越小越灵敏）"));
        sbDeadzone = seek(0, 30, (int)(follow.deadzone*100), v -> follow.deadzone = v/100f);
        p.addView(sbDeadzone);

        p.addView(label("平滑（越小越跟手，越大越柔）"));
        sbSmooth = seek(5, 100, (int)(follow.smoothing*100), v -> follow.smoothing = v/100f);
        p.addView(sbSmooth);

        p.addView(label("提词速度"));
        sbSpeed = seek(1, 80, 10, v -> prompter.setSpeed(v/10f));
        p.addView(sbSpeed);

        p.addView(label("提词字号"));
        sbFont = seek(16, 60, 28, v -> prompter.setFontSize(v));
        p.addView(sbFont);

        LinearLayout sw = new LinearLayout(this);
        sw.setOrientation(LinearLayout.HORIZONTAL);
        sw.addView(swtch("镜像", false, v -> prompter.setMirrored(v)));
        sw.addView(swtch("边框", true, v -> prompter.setShowBorder(v)));
        sw.addView(swtch("水平反转", false, v -> follow.invertX = v));
        sw.addView(swtch("俯仰反转", false, v -> follow.invertY = v));
        p.addView(sw);

        p.addView(label("协议变体（云台不动时逐项切换）"));
        spChannel = spinner(new String[]{"通道3(默认)", "通道2"}, 0, pos -> GimbalProtocol.channel = pos==0?3:2);
        spInnerCs = spinner(new String[]{"内层校验开", "内层校验关"}, 0, pos -> GimbalProtocol.innerChecksum = pos==0);
        spOuterCrc = spinner(new String[]{"外层CRC8", "外层累加"}, 0, pos -> GimbalProtocol.outerCrc = pos==0);
        p.addView(spChannel); p.addView(spInnerCs); p.addView(spOuterCrc);

        p.addView(label("台词内容"));
        etScript = new EditText(this);
        etScript.setHeight(160);
        etScript.setTextColor(0xFFFFFFFF);
        etScript.setHint("输入或粘贴台词…");
        p.addView(etScript);
        p.addView(btn("应用台词", v -> prompter.setText(etScript.getText().toString())));

        p.addView(btn("解锁横竖屏锁定", v -> { follow.manualUnlock(); toast("已解锁方向"); }));
        p.addView(btn("关闭设置", v -> settingsPanel.setVisibility(View.GONE)));
        return p;
    }

    private void toggleSettings() {
        settingsPanel.setVisibility(settingsPanel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE);
    }

    private void updateDevices(List<android.bluetooth.BluetoothDevice> ds) {
        deviceList.removeAllViews();
        for (android.bluetooth.BluetoothDevice d : ds) {
            Button b = btn("连接: " + d.getName(), v -> ble.connect(d));
            deviceList.addView(b);
        }
    }

    private void appendLog(String l) {
        logText.setText(l + "\n" + logText.getText());
        if (logText.getText().length() > 600) {
            String s = logText.getText().toString();
            logText.setText(s.substring(0, 500));
        }
    }

    // ---------------- 相机 + 人脸检测 ----------------
    private void startCamera() {
        ListenableFuture<ProcessCameraProvider> f = ProcessCameraProvider.getInstance(this);
        f.addListener(() -> {
            try {
                ProcessCameraProvider cp = f.get();
                Preview preview = new Preview.Builder().build();
                preview.setSurfaceProvider(previewView.getSurfaceProvider());

                ImageAnalysis analysis = new ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build();
                analysis.setAnalyzer(cameraExecutor, image -> analyzeFrame(image));

                cp.unbindAll();
                cp.bindToLifecycle(this, CameraSelector.DEFAULT_FRONT_CAMERA, preview, analysis);
            } catch (Exception e) {
                runOnUiThread(() -> appendLog("相机错误: " + e.getMessage()));
            }
        }, ContextCompat.getMainExecutor(this));
    }

    @androidx.camera.core.ExperimentalGetImage
    private void analyzeFrame(ImageProxy image) {
        android.media.Image media = image.getImage();
        if (media == null) { image.close(); return; }
        InputImage input = InputImage.fromMediaImage(media, image.getImageInfo().getRotationDegrees());
        faceDetector.process(input)
                .addOnSuccessListener(faces -> {
                    if (faces == null || faces.isEmpty()) { follow.reset(); return; }
                    Face face = faces.get(0);
                    android.graphics.Rect b = face.getBoundingBox();
                    float cx = b.left + b.width()/2f;
                    float cy = b.top + b.height()/2f;
                    int w = image.getWidth(), h = image.getHeight();
                    float dx = (cx - w/2f) / (w/2f);
                    float dy = (cy - h/2f) / (h/2f);
                    int[] cmd = follow.compute(dx, dy);
                    if (cmd != null) {
                        byte[] frame = GimbalProtocol.yawPitch(cmd[0], cmd[1]);
                        ble.send(frame);
                        // 横竖屏姿态判定（人脸宽高比作为参考）
                        boolean landscape = b.width() > b.height() * 1.15f;
                        follow.updateOrientation(landscape);
                    }
                })
                .addOnFailureListener(e -> {})
                .addOnCompleteListener(t -> image.close());
    }

    private void sendTurn(int yaw, int pitch) {
        ble.send(GimbalProtocol.yawPitch(yaw, pitch));
    }

    // ---------------- 小工具 ----------------
    private Button btn(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextSize(12);
        b.setPadding(8, 4, 8, 4);
        b.setOnClickListener(l);
        return b;
    }
    private TextView label(String t) {
        TextView v = new TextView(this);
        v.setText(t); v.setTextColor(0xFFAAAAAA);
        v.setPadding(0, 8, 0, 0);
        return v;
    }
    private SeekBar seek(int min, int max, int cur, java.util.function.IntConsumer cb) {
        SeekBar s = new SeekBar(this);
        s.setMax(max - min);
        s.setProgress(cur - min);
        s.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar sb, int p, boolean f) { cb.accept(p + min); }
            public void onStartTrackingTouch(SeekBar sb) {}
            public void onStopTrackingTouch(SeekBar sb) {}
        });
        return s;
    }
    private Switch swtch(String t, boolean def, java.util.function.Consumer<Boolean> cb) {
        Switch s = new Switch(this);
        s.setText(t); s.setChecked(def);
        s.setOnCheckedChangeListener((b, v) -> cb.accept(v));
        return s;
    }
    private Spinner spinner(String[] items, int def, java.util.function.IntConsumer cb) {
        Spinner s = new Spinner(this);
        ArrayAdapter<String> a = new ArrayAdapter<>(this, android.R.layout.simple_spinner_item, items);
        a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        s.setAdapter(a);
        s.setSelection(def);
        s.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onItemSelected(AdapterView<?> p, View v, int pos, long id) { cb.accept(pos); }
            public void onNothingSelected(AdapterView<?> p) {}
        });
        return s;
    }
    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (cameraExecutor != null) cameraExecutor.shutdown();
        if (faceDetector != null) faceDetector.close();
        if (ble != null) ble.disconnect();
    }
}
