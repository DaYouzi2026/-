package com.gimbalcam.app;

import android.Manifest;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.camera.core.*;
import androidx.camera.core.ImageCapture.*;
import androidx.camera.video.*;
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

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 云台相机 GimbalCam v2.0 — 相机优先，界面对标 DJI Mimo。
 * 提词器为按需浮层（默认隐藏）。内置自检面板，方便真机定位"连没连上/发了什么/收到什么"。
 */
public class MainActivity extends AppCompatActivity {

    private PreviewView previewView;
    private PrompterView prompter;
    private TextView statusText, logText;
    private BleController ble;
    private FollowEngine follow = new FollowEngine();
    private FaceDetector faceDetector;
    private ImageCapture imageCapture;
    private VideoCapture<Recorder> videoCapture;
    private Recorder recorder;
    private ExecutorService cameraExecutor;

    private boolean showPrompter = false;    // 提词器默认隐藏，按需点出
    private boolean diagOpen = false;
    private boolean isVideoMode = false;
    private static final int REQ_PERMS = 100;

    // 设置
    private SeekBar sbGain, sbDeadzone, sbSmooth, sbSpeed, sbFont;
    private Switch swInvertX, swInvertY;
    private Spinner spChannel, spInnerCs, spOuterCrc;
    private EditText etScript;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(Color.BLACK);
        requestPermsIfNeeded();
        buildUI();
        ble = new BleController(this, new BleController.Listener() {
            public void onState(String s) { runOnUiThread(() -> statusText.setText(s)); }
            public void onDevices(List<android.bluetooth.BluetoothDevice> ds) { runOnUiThread(() -> updateDevices(ds)); }
            public void onLog(String l) { runOnUiThread(() -> appendLog(l)); }
        });
        faceDetector = FaceDetection.getClient(new FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .build());
        cameraExecutor = Executors.newSingleThreadExecutor();
        if (allPerms()) { startCamera(); ble.scan(); }
    }

    private void requestPermsIfNeeded() {
        if (!allPerms()) {
            ActivityCompat.requestPermissions(this, new String[]{
                    Manifest.permission.CAMERA,
                    Manifest.permission.RECORD_AUDIO,
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.ACCESS_FINE_LOCATION
            }, REQ_PERMS);
        }
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

    // ==================== UI ====================
    private LinearLayout deviceList, diagPanel, settingsPanel;

    private void buildUI() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        // 1) 全屏相机预览
        previewView = new PreviewView(this);
        root.addView(previewView, new FrameLayout.LayoutParams(-1, -1));

        // 2) 提词器浮层（默认隐藏）
        prompter = new PrompterView(this);
        prompter.setVisibility(View.GONE);
        root.addView(prompter, new FrameLayout.LayoutParams(-1, -1));

        // 3) 顶部状态条
        statusText = new TextView(this);
        statusText.setText("云台相机 · 扫描中");
        statusText.setTextColor(Color.WHITE);
        statusText.setTextSize(13);
        statusText.setBackgroundColor(0x99000000);
        statusText.setPadding(20, 24, 20, 16);
        FrameLayout.LayoutParams stLp = new FrameLayout.LayoutParams(-1, -2);
        stLp.gravity = Gravity.TOP;
        statusText.setOnClickListener(v -> ble.scan()); // 点状态栏重扫
        root.addView(statusText, stLp);

        // 4) 右上角工具列（竖排）
        LinearLayout rail = new LinearLayout(this);
        rail.setOrientation(LinearLayout.VERTICAL);
        rail.setGravity(Gravity.CENTER_HORIZONTAL);
        int railTop = 130;
        rail.setPadding(0, railTop, 16, 0);
        rail.addView(iconBtn("跟随", v -> {
            follow.enabled = !follow.enabled; follow.reset();
            toast(follow.enabled ? "智能跟随 开" : "智能跟随 关");
        }));
        rail.addView(iconBtn("云台", v -> toast("用底部方向键手动控制云台")));
        rail.addView(iconBtn("提词", v -> {
            showPrompter = !showPrompter;
            prompter.setVisibility(showPrompter ? View.VISIBLE : View.GONE);
            toast(showPrompter ? "提词器 开" : "提词器 关");
        }));
        rail.addView(iconBtn("诊断", v -> toggleDiag()));
        rail.addView(iconBtn("设置", v -> toggleSettings()));
        FrameLayout.LayoutParams railLp = new FrameLayout.LayoutParams(-2, -2);
        railLp.gravity = Gravity.TOP | Gravity.END;
        root.addView(rail, railLp);

        // 5) 底部：模式栏 + 快门
        LinearLayout bottom = new LinearLayout(this);
        bottom.setOrientation(LinearLayout.VERTICAL);
        bottom.setGravity(Gravity.CENTER_HORIZONTAL);
        bottom.setPadding(0, 0, 0, 24);

        LinearLayout modes = new LinearLayout(this);
        modes.setGravity(Gravity.CENTER);
        final TextView mPhoto = pill("照片"), mVideo = pill("视频"), mPortrait = pill("人像");
        mPhoto.setTextColor(Color.WHITE);
        modes.addView(mPhoto); modes.addView(mVideo); modes.addView(mPortrait);
        mPhoto.setOnClickListener(v -> { isVideoMode=false; mPhoto.setTextColor(Color.WHITE); mVideo.setTextColor(Color.GRAY); toast("照片模式"); });
        mVideo.setOnClickListener(v -> { isVideoMode=true; mVideo.setTextColor(Color.WHITE); mPhoto.setTextColor(Color.GRAY); toast("视频模式"); });
        mPortrait.setOnClickListener(v -> toast("人像（对焦人脸）"));
        bottom.addView(modes);

        LinearLayout shutterRow = new LinearLayout(this);
        shutterRow.setGravity(Gravity.CENTER);
        shutterRow.setPadding(0, 16, 0, 0);
        Button shutter = roundBtn("●");
        shutter.setOnClickListener(v -> takeShot());
        shutterRow.addView(shutter);
        bottom.addView(shutterRow);

        FrameLayout.LayoutParams bLp = new FrameLayout.LayoutParams(-1, -2);
        bLp.gravity = Gravity.BOTTOM;
        root.addView(bottom, bLp);

        // 6) 左下手动方向键（小，半透明）
        LinearLayout dpad = new LinearLayout(this);
        dpad.setOrientation(LinearLayout.VERTICAL);
        dpad.setBackgroundColor(0x55000000);
        LinearLayout r1 = new LinearLayout(this);
        r1.addView(miniBtn("◀", v -> sendTurn(-300, 0)));
        r1.addView(miniBtn("●", v -> sendTurn(0, 0)));
        r1.addView(miniBtn("▶", v -> sendTurn(300, 0)));
        dpad.addView(r1);
        LinearLayout r2 = new LinearLayout(this);
        r2.addView(miniBtn("▲", v -> sendTurn(0, 300)));
        r2.addView(miniBtn("▼", v -> sendTurn(0, -300)));
        dpad.addView(r2);
        FrameLayout.LayoutParams dLp = new FrameLayout.LayoutParams(-2, -2);
        dLp.gravity = Gravity.BOTTOM | Gravity.START;
        dLp.bottomMargin = 130;
        root.addView(dpad, dLp);

        // 7) 日志小窗（左下，可隐藏）
        logText = new TextView(this);
        logText.setTextColor(0xFF00FF88);
        logText.setTextSize(10);
        logText.setBackgroundColor(0x88000000);
        logText.setMaxLines(5);
        FrameLayout.LayoutParams logLp = new FrameLayout.LayoutParams(420, -2);
        logLp.gravity = Gravity.BOTTOM | Gravity.END;
        logLp.bottomMargin = 20;
        root.addView(logText, logLp);

        // 8) 设备列表（顶部下，扫描结果）
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        deviceList.setBackgroundColor(0xCC000000);
        FrameLayout.LayoutParams devLp = new FrameLayout.LayoutParams(-1, -2);
        devLp.gravity = Gravity.TOP;
        devLp.topMargin = 70;
        root.addView(deviceList, devLp);

        // 9) 自检面板 / 设置面板（底部弹出，默认隐藏）
        diagPanel = buildDiag();
        diagPanel.setVisibility(View.GONE);
        FrameLayout.LayoutParams diagLp = new FrameLayout.LayoutParams(-1, -2);
        diagLp.gravity = Gravity.BOTTOM;
        root.addView(diagPanel, diagLp);

        settingsPanel = buildSettings();
        settingsPanel.setVisibility(View.GONE);
        FrameLayout.LayoutParams setLp = new FrameLayout.LayoutParams(-1, -2);
        setLp.gravity = Gravity.BOTTOM;
        root.addView(settingsPanel, setLp);

        setContentView(root);
    }

    // ==================== 自检面板 ====================
    private TextView diagInfo;
    private LinearLayout buildDiag() {
        LinearLayout p = panelShell("自检 / 协议调试");
        diagInfo = new TextView(this);
        diagInfo.setTextColor(0xFFCCCCCC);
        diagInfo.setTextSize(11);
        diagInfo.setText("连接状态见顶部。发命令后看右下日志：\n→ 是自己发的帧，← 是云台回的帧。");
        p.addView(diagInfo);

        p.addView(label("① 先测手动转头（点左/右，看云台动不动）"));
        LinearLayout dir = new LinearLayout(this);
        dir.addView(btn("左", v -> sendTurn(-400, 0)));
        dir.addView(btn("停", v -> sendTurn(0, 0)));
        dir.addView(btn("右", v -> sendTurn(400, 0)));
        dir.addView(btn("上", v -> sendTurn(0, 400)));
        dir.addView(btn("下", v -> sendTurn(0, -400)));
        p.addView(dir);

        p.addView(label("② 转头没动？逐条试初始化帧（每点一次等 1 秒看云台）"));
        LinearLayout init = new LinearLayout(this);
        init.addView(btn("复位0x22", v -> { ble.send(GimbalProtocol.initReset22()); log("已发初始化帧 0x22 复位"); }));
        init.addView(btn("开关0x49", v -> { ble.send(GimbalProtocol.initToggle49()); log("已发初始化帧 0x49 开关"); }));
        init.addView(btn("模式0x31", v -> { ble.send(GimbalProtocol.initMode31()); log("已发初始化帧 0x31 模式"); }));
        p.addView(init);

        p.addView(label("③ 还不动？切协议变体（每切一次重测转头）"));
        LinearLayout var = new LinearLayout(this);
        spChannel = spinner(new String[]{"通道3(默认)", "通道2"}, 0, pos -> GimbalProtocol.channel = pos==0?3:2);
        spInnerCs = spinner(new String[]{"内层校验开", "内层校验关"}, 0, pos -> GimbalProtocol.innerChecksum = pos==0);
        spOuterCrc = spinner(new String[]{"外层CRC8", "外层累加"}, 0, pos -> GimbalProtocol.outerCrc = pos==0);
        var.addView(spChannel); var.addView(spInnerCs); var.addView(spOuterCrc);
        p.addView(var);

        p.addView(label("④ 蓝牙列表 / 重扫"));
        p.addView(btn("重新扫描云台", v -> { ble.scan(); toast("已开始扫描"); }));
        p.addView(btn("关闭自检", v -> toggleDiag()));
        return p;
    }

    private void toggleDiag() {
        diagOpen = !diagOpen;
        diagPanel.setVisibility(diagOpen ? View.VISIBLE : View.GONE);
        if (diagOpen) settingsPanel.setVisibility(View.GONE);
    }

    // ==================== 设置面板 ====================
    private LinearLayout buildSettings() {
        LinearLayout p = panelShell("设置");
        p.addView(label("跟随灵敏度（越大越灵敏）"));
        p.addView(sbGain = seek(1, 300, (int)(follow.gain*100), v -> follow.gain = v/100f));
        p.addView(label("死区（越大越稳，越小越灵敏）"));
        p.addView(sbDeadzone = seek(0, 30, (int)(follow.deadzone*100), v -> follow.deadzone = v/100f));
        p.addView(label("平滑（越小越跟手，越大越柔）"));
        p.addView(sbSmooth = seek(5, 100, (int)(follow.smoothing*100), v -> follow.smoothing = v/100f));
        p.addView(label("提词速度"));
        p.addView(sbSpeed = seek(1, 80, 10, v -> prompter.setSpeed(v/10f)));
        p.addView(label("提词字号"));
        p.addView(sbFont = seek(16, 60, 28, v -> prompter.setFontSize(v)));
        LinearLayout sw = new LinearLayout(this);
        sw.addView(swtch("水平反转", false, v -> follow.invertX = v));
        sw.addView(swtch("俯仰反转", false, v -> follow.invertY = v));
        p.addView(sw);
        p.addView(label("台词内容"));
        etScript = new EditText(this);
        etScript.setHeight(150);
        etScript.setTextColor(Color.WHITE);
        etScript.setHint("输入或粘贴台词…");
        p.addView(etScript);
        p.addView(btn("应用台词并打开提词器", v -> {
            prompter.setText(etScript.getText().toString());
            showPrompter = true; prompter.setVisibility(View.VISIBLE);
        }));
        p.addView(btn("解锁横竖屏锁定", v -> { follow.manualUnlock(); toast("已解锁方向"); }));
        p.addView(btn("关闭设置", v -> settingsPanel.setVisibility(View.GONE)));
        return p;
    }

    private void toggleSettings() {
        settingsPanel.setVisibility(settingsPanel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE);
        if (settingsPanel.getVisibility()==View.VISIBLE) diagPanel.setVisibility(View.GONE);
    }

    private LinearLayout panelShell(String title) {
        LinearLayout p = new LinearLayout(this);
        p.setOrientation(LinearLayout.VERTICAL);
        p.setBackgroundColor(0xF0111111);
        p.setPadding(24, 20, 24, 24);
        TextView t = new TextView(this);
        t.setText(title);
        t.setTextColor(Color.WHITE);
        t.setTextSize(16);
        t.setPadding(0, 0, 0, 12);
        p.addView(t);
        return p;
    }

    private void updateDevices(List<android.bluetooth.BluetoothDevice> ds) {
        deviceList.removeAllViews();
        for (android.bluetooth.BluetoothDevice d : ds) {
            String n = d.getName() == null ? "未知设备" : d.getName();
            deviceList.addView(btn("连接 " + n, v -> { ble.connect(d); deviceList.setVisibility(View.GONE); }));
        }
        if (!ds.isEmpty()) deviceList.setVisibility(View.VISIBLE);
    }

    private void appendLog(String l) {
        logText.setText(l + "\n" + logText.getText());
        String cur = logText.getText().toString();
        if (cur.length() > 500) logText.setText(cur.substring(0, 400));
    }
    private void log(String s) { appendLog("· " + s); }

    // ==================== 相机 ====================
    private void startCamera() {
        ListenableFuture<ProcessCameraProvider> f = ProcessCameraProvider.getInstance(this);
        f.addListener(() -> {
            try {
                ProcessCameraProvider cp = f.get();
                Preview preview = new Preview.Builder().build();
                preview.setSurfaceProvider(previewView.getSurfaceProvider());

                imageCapture = new ImageCapture.Builder().build();
                recorder = new Recorder.Builder().build();
                videoCapture = VideoCapture.withOutput(recorder);

                ImageAnalysis analysis = new ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build();
                analysis.setAnalyzer(cameraExecutor, this::analyzeFrame);

                cp.unbindAll();
                cp.bindToLifecycle(this, CameraSelector.DEFAULT_FRONT_CAMERA,
                        preview, imageCapture, videoCapture, analysis);
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
                    float cx = b.left + b.width()/2f, cy = b.top + b.height()/2f;
                    float dx = (cx - image.getWidth()/2f) / (image.getWidth()/2f);
                    float dy = (cy - image.getHeight()/2f) / (image.getHeight()/2f);
                    int[] cmd = follow.compute(dx, dy);
                    if (cmd != null) {
                        ble.send(GimbalProtocol.yawPitch(cmd[0], cmd[1]));
                        follow.updateOrientation(b.width() > b.height()*1.15f);
                    }
                })
                .addOnFailureListener(e -> {})
                .addOnCompleteListener(t -> image.close());
    }

    private void takeShot() {
        if (isVideoMode) {
            toast("视频拍摄请用系统相机录制（演示版）");
            return;
        }
        if (imageCapture == null) { toast("相机未就绪"); return; }
        File dir = new File(getExternalFilesDir(null), "GimbalCam");
        if (!dir.exists()) dir.mkdirs();
        String name = "GC_" + new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(new java.util.Date()) + ".jpg";
        File file = new File(dir, name);
        ImageCapture.OutputFileOptions opts = new ImageCapture.OutputFileOptions.Builder(file).build();
        imageCapture.takePicture(opts, ContextCompat.getMainExecutor(this),
                new ImageCapture.OnImageSavedCallback() {
                    public void onImageSaved(ImageCapture.OutputFileResults r) { toast("已拍照：" + name); }
                    public void onError(ImageCaptureException e) { toast("拍照失败：" + e.getMessage()); }
                });
    }

    private void sendTurn(int yaw, int pitch) {
        ble.send(GimbalProtocol.yawPitch(yaw, pitch));
    }

    // ==================== 小工具 ====================
    private Button btn(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text); b.setTextSize(12);
        b.setPadding(10, 6, 10, 6);
        b.setOnClickListener(l);
        return b;
    }
    private Button iconBtn(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text); b.setTextSize(12);
        b.setBackgroundColor(0xAA222222);
        b.setTextColor(Color.WHITE);
        b.setPadding(14, 10, 14, 10);
        b.setOnClickListener(l);
        return b;
    }
    private Button miniBtn(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text); b.setTextSize(14);
        b.setMinimumWidth(90);
        b.setOnClickListener(l);
        return b;
    }
    private Button roundBtn(String text) {
        Button b = new Button(this);
        b.setText(text); b.setTextSize(28);
        b.setTextColor(Color.WHITE);
        b.setBackgroundColor(0xFFE8E8E8);
        b.setWidth(160);
        return b;
    }
    private TextView pill(String text) {
        TextView t = new TextView(this);
        t.setText(text); t.setTextSize(15);
        t.setTextColor(Color.GRAY);
        t.setPadding(28, 10, 28, 10);
        return t;
    }
    private TextView label(String t) {
        TextView v = new TextView(this);
        v.setText(t); v.setTextColor(0xFFAAAAAA);
        v.setPadding(0, 12, 0, 4);
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
        s.setTextColor(Color.WHITE);
        s.setOnCheckedChangeListener((b, v) -> cb.accept(v));
        return s;
    }
    private Spinner spinner(String[] items, int def, java.util.function.IntConsumer cb) {
        Spinner s = new Spinner(this);
        ArrayAdapter<String> a = new ArrayAdapter<>(this, android.R.layout.simple_spinner_item, items);
        a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        s.setAdapter(a); s.setSelection(def);
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
