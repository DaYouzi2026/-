package com.gimbalcam.app;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** BLE 连接与指令写入，兼容勤蓝两套 UUID 变体 */
public class BleController {

    // 型号A（标准 16-bit）与型号B（私有 128-bit）
    private static final UUID[] SERVICE_UUIDS = {
            UUID.fromString("0000fe00-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("02f00000-0000-0000-0000-00000000fe00")
    };
    private static final UUID[] WRITE_UUIDS = {
            UUID.fromString("0000ff01-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("02f00000-0000-0000-0000-00000000ff01")
    };
    private static final UUID[] NOTIFY_UUIDS = {
            UUID.fromString("0000ff02-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("02f00000-0000-0000-0000-00000000ff02")
    };
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    public interface Listener {
        void onState(String state);          // 连接状态文本
        void onDevices(List<BluetoothDevice> devices);
        void onLog(String log);
    }

    private final Context ctx;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic writeChar;
    private int uuidVariant = 0;   // 0=标准, 1=私有 —— 真机自动探测
    public boolean connected = false;

    public BleController(Context ctx, Listener listener) {
        this.ctx = ctx;
        this.listener = listener;
        this.adapter = BluetoothAdapter.getDefaultAdapter();
        final Listener L = listener;
        this.leScanCallback = (device, rssi, scanRecord) -> {
            if (device.getName() != null) {
                main.post(() -> L.onDevices(java.util.Collections.singletonList(device)));
            }
        };
    }

    public boolean bluetoothAvailable() { return adapter != null && adapter.isEnabled(); }

    /** 开始扫描（经典 BLE 扫描） */
    public void scan() {
        if (adapter == null) { listener.onState("无蓝牙"); return; }
        listener.onState("扫描中…");
        adapter.startLeScan(leScanCallback);
        main.postDelayed(() -> {
            adapter.stopLeScan(leScanCallback);
            listener.onState("扫描结束");
        }, 8000);
    }

    private final BluetoothAdapter.LeScanCallback leScanCallback;

    public void connect(BluetoothDevice device) {
        listener.onState("连接中… " + device.getName());
        // Android 12+ 需要 BLUETOOTH_CONNECT 权限，由 MainActivity 负责申请
        gatt = device.connectGatt(ctx, false, gattCallback);
    }

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                main.post(() -> listener.onState("已连接, 发现服务…"));
                g.discoverServices();
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connected = false;
                main.post(() -> listener.onState("已断开"));
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            boolean ok = setupVariant(g, 0) || setupVariant(g, 1);
            main.post(() -> {
                if (ok) {
                    connected = true;
                    listener.onState("已就绪 ✓ (UUID变体" + uuidVariant + ")");
                    // 关键：原版连接成功后 500ms 发握手帧 GW20 授权云台。
                    // 不发这一帧，云台不会响应任何转头/跟随指令 —— 这是"连上没反应"的根因。
                    handshakeStep = 0;
                    main.postDelayed(BleController.this::sendHandshake, 500);
                } else {
                    listener.onState("未找到控制特征");
                }
            });
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            // 写入完成回调
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            main.post(() -> listener.onLog("← " + GimbalProtocol.hex(c.getValue())));
        }
    };

    private boolean setupVariant(BluetoothGatt g, int variant) {
        BluetoothGattService svc = g.getService(SERVICE_UUIDS[variant]);
        if (svc == null) return false;
        BluetoothGattCharacteristic w = svc.getCharacteristic(WRITE_UUIDS[variant]);
        if (w == null) return false;
        writeChar = w;
        uuidVariant = variant;
        // 开启通知
        BluetoothGattCharacteristic n = svc.getCharacteristic(NOTIFY_UUIDS[variant]);
        if (n != null) {
            g.setCharacteristicNotification(n, true);
            for (BluetoothGattDescriptor d : n.getDescriptors()) {
                d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                g.writeDescriptor(d);
            }
        }
        return true;
    }

    /** 写入指令（带节流，避免写太快导致 BLE 栈丢包） */
    private long lastWrite = 0;
    public void send(byte[] data) {
        if (!connected || writeChar == null) return;
        long now = System.currentTimeMillis();
        if (now - lastWrite < 20) {           // 最小 20ms 间隔
            main.postDelayed(() -> doWrite(data), 20 - (now - lastWrite));
        } else {
            doWrite(data);
        }
        lastWrite = now;
    }

    private void doWrite(byte[] data) {
        try {
            writeChar.setValue(data);
            gatt.writeCharacteristic(writeChar);
            listener.onLog("→ " + GimbalProtocol.hex(data));
        } catch (SecurityException e) {
            listener.onLog("写入失败: 权限");
        }
    }

    // ---- 连接握手：依次尝试原版的几种授权帧，覆盖不同型号/加密变体 ----
    private int handshakeStep = 0;
    private void sendHandshake() {
        if (!connected || writeChar == null) return;
        final byte[][] candidates = new byte[][]{
                GimbalProtocol.handshakeGW20(),      // 最常见：非加密 GW20 累加和
                GimbalProtocol.handshakeGW20Crc(),   // 加密型号 GW20 CRC8
                GimbalProtocol.handshakeGW10()       // AFI_V5_New：GW10
        };
        final String[] names = {"GW20(累加和)", "GW20(CRC8)", "GW10"};
        if (handshakeStep >= candidates.length) {
            listener.onState("已就绪 ✓ 握手已发(" + (candidates.length) + "种), 请试转头");
            return;
        }
        listener.onLog("握手 " + (handshakeStep + 1) + "/" + candidates.length
                + " " + names[handshakeStep] + ": " + GimbalProtocol.hex(candidates[handshakeStep]));
        doWrite(candidates[handshakeStep]);
        handshakeStep++;
        main.postDelayed(this::sendHandshake, 400);
    }

    /** 手动重发握手（诊断面板按钮） */
    public void resendHandshake() {
        handshakeStep = 0;
        main.post(this::sendHandshake);
    }

    public void disconnect() {
        if (gatt != null) { gatt.disconnect(); gatt.close(); gatt = null; }
        connected = false;
    }
}
