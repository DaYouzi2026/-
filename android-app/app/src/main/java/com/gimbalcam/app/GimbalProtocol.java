package com.gimbalcam.app;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * 勤蓝/Netviv 云台 BLE 协议帧构造（逆向自 Gimbal Play v2.5.57）
 *
 * 内层帧: 55 02 [type] [cmd] [n] [n] [params...] [累加校验]
 * 外层帧: FF FF [lenHi] [lenLo] [channel] [内层帧] [CRC8]
 */
public final class GimbalProtocol {

    // ---- 真机可调变体（用户可在设置里切换，找到云台能识别的组合）----
    public static int channel = 3;          // 外层通道，默认 3；部分型号为 2
    public static boolean innerChecksum = true;  // 内层累加校验，默认开
    public static boolean outerCrc = true;       // 外层 CRC8，默认开；关闭则用累加校验

    // ---- 命令码 ----
    public static final byte CMD_YAW_PITCH = 0x23;   // 转头（水平/俯仰）
    public static final byte CMD_TARGET    = 0x11;   // 目标坐标
    public static final byte CMD_TOGGLE    = 0x22;   // 开关类
    public static final byte CMD_SETTING   = 0x25;   // 设置类
    public static final byte CMD_MODE      = 0x31;   // 模式
    public static final byte CMD_SWITCH6   = 0x49;   // 6字节开关
    public static final byte CMD_SINGLE    = 0x61;   // 单字节设置

    /** 内层累加校验：从第2字节起到末尾求和取低8位 */
    private static byte innerCheck(byte[] frame) {
        int sum = 0;
        for (int i = 1; i < frame.length; i++) sum += (frame[i] & 0xFF);
        return (byte) (sum & 0xFF);
    }

    /** CRC-8/MAXIM: 多项式反射0x8D, 初值0 */
    public static byte crc8(byte[] data, int len) {
        byte crc = 0;
        for (int i = 0; i < len; i++) {
            crc ^= data[i];
            for (int j = 8; j > 0; j--) {
                if ((crc & 0x80) != 0) crc = (byte) ((crc << 1) ^ 0x8D);
                else crc = (byte) (crc << 1);
            }
        }
        return crc;
    }

    /** 构造内层帧: 55 02 type cmd n n [params] [checksum] */
    private static byte[] innerFrame(byte type, byte cmd, byte[] params) {
        int n = params.length;
        ByteBuffer b = ByteBuffer.allocate(7 + n + (innerChecksum ? 1 : 0))
                .order(ByteOrder.LITTLE_ENDIAN);
        b.put((byte) 0x55);
        b.put(type);
        b.put((byte) 0x0B);      // 长度字段（逆向固定值，多数命令用 0x0B/0x0C）
        b.put(cmd);
        b.put((byte) n);
        b.put((byte) n);
        b.put(params);
        byte[] raw = b.array();
        if (!innerChecksum) return raw;
        byte[] out = new byte[raw.length + 1];
        System.arraycopy(raw, 0, out, 0, raw.length);
        out[raw.length] = innerCheck(raw);
        return out;
    }

    /**
     * 外层封装: FF FF [lenHi][lenLo][channel][inner][crc]
     * 长度字段 = 内层长度 + 2（通道1字节 + CRC1字节）——逆向 gp1.OooO0Oo 确认。
     * 之前写成 +1 导致云台长度校验失败直接丢包，是"连上没反应"的根因。
     */
    public static byte[] wrap(byte[] inner) {
        // 逆向 gp1.OooO0Oo 确认：长度字段 = 内层长度 + 2（通道1 + CRC1）
        int lenField = inner.length + 2;
        // core = [lenHi][lenLo][channel][inner...]，长度固定 3 + inner.length
        byte[] core = new byte[3 + inner.length];
        core[0] = (byte) ((lenField >> 8) & 0xFF);
        core[1] = (byte) (lenField & 0xFF);
        core[2] = (byte) channel;
        System.arraycopy(inner, 0, core, 3, inner.length);

        byte check;
        if (outerCrc) {
            // CRC 覆盖整个 core（lenHi..inner 末尾），等价于官方 ye3.OooOO0(v4, n+3)
            check = crc8(core, core.length);
        } else {
            int sum = 0;
            for (byte b : core) sum += (b & 0xFF);
            check = (byte) (sum & 0xFF);
        }

        byte[] out = new byte[2 + core.length + 1];  // FF FF + core + CRC
        out[0] = (byte) 0xFF;
        out[1] = (byte) 0xFF;
        System.arraycopy(core, 0, out, 2, core.length);
        out[out.length - 1] = check;
        return out;
    }

    /** 转头指令: 0x23 + yaw/pitch (±1000) */
    public static byte[] yawPitch(int yaw, int pitch) {
        yaw = clamp(yaw, -1000, 1000);
        pitch = clamp(pitch, -1000, 1000);
        ByteBuffer p = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN);
        p.putShort((short) yaw);
        p.putShort((short) pitch);
        p.put((byte) 0);
        return wrap(innerFrame((byte) 0x02, CMD_YAW_PITCH, p.array()));
    }

    /** 目标坐标指令: 0x11 + 3×short (x,y,z ×100) */
    public static byte[] target(float x, float y, float z) {
        ByteBuffer p = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN);
        p.putShort((short) (x * 100));
        p.putShort((short) (y * 100));
        p.putShort((short) (z * 100));
        return wrap(innerFrame((byte) 0x02, CMD_TARGET, p.array()));
    }

    /** 设置指令: 0x25 + 子功能 + 值 */
    public static byte[] setting(int subFunc, int value) {
        return wrap(innerFrame((byte) 0x02, CMD_SETTING,
                new byte[]{(byte) subFunc, (byte) value}));
    }

    /** 开关指令: 0x22 + 0/1 */
    public static byte[] toggle(boolean on) {
        return wrap(innerFrame((byte) 0x02, CMD_TOGGLE, new byte[]{(byte) (on ? 1 : 0)}));
    }

    /**
     * 初始化/复位候选帧（逆向 oO00Oo0.OooOo00）。
     * 不同型号 Initialize 帧不同，放在自检面板里让真机逐条试，不自动发。
     * 候选1：0x49 六字节全 0（proType==2 的 OooOo0）
     */
    public static byte[] initToggle49() {
        return wrap(innerFrame((byte) 0x02, CMD_SWITCH6,
                new byte[]{0, 0, 0, 0, 0, 0}));
    }

    /**
     * 候选2：0x22 复位帧 AA 55 00 08 22 02 00 00 00 00 00 00（proType==9，非F10）
     * 此帧内层首字节为 0xAA、长度字段 0x08，与普通帧不同，单独构造。
     */
    public static byte[] initReset22() {
        byte[] inner = new byte[]{
                (byte) 0xAA, 0x55, 0x00, 0x08, 0x22, 0x02,
                0, 0, 0, 0, 0, 0
        };
        // 内层累加校验（从第2字节起）
        int s = 0;
        for (int i = 1; i < inner.length; i++) s += (inner[i] & 0xFF);
        byte[] framed = new byte[inner.length + 1];
        System.arraycopy(inner, 0, framed, 0, inner.length);
        framed[inner.length] = (byte) (s & 0xFF);
        return wrap(framed);
    }

    /** 候选3：0x31 模式设置 两字节全 0 */
    public static byte[] initMode31() {
        return wrap(innerFrame((byte) 0x02, CMD_MODE, new byte[]{0, 0}));
    }

    // ============================================================
    // 握手帧 —— 逆向自原版 getAppConnected()，是"连上没反应"的根因
    // 原版连接成功后发 ASCII "GW20" 让云台授权；不发则所有转头指令被忽略。
    // 封装 = FF FF [lenHi][lenLo][channel=3] [ASCII payload] [check]
    //   len 字段 = payload.length + 2；check 累加和(非加密) / CRC8(加密型号)
    // ============================================================

    /** 官方 gp1.OooO0Oo(channel, payload, check) 封装，与二进制帧共用同一外层 */
    private static byte[] wrapPayload(byte[] payload, boolean useCrc) {
        int lenField = payload.length + 2;
        byte[] core = new byte[3 + payload.length];
        core[0] = (byte) ((lenField >> 8) & 0xFF);
        core[1] = (byte) (lenField & 0xFF);
        core[2] = (byte) channel;              // 默认 3
        System.arraycopy(payload, 0, core, 3, payload.length);

        byte check;
        if (useCrc) {
            check = crc8(core, core.length);   // 覆盖 lenHi..payload 末尾
        } else {
            int sum = 0;
            for (byte b : core) sum += (b & 0xFF);
            check = (byte) (sum & 0xFF);       // gp1.OooO00o 累加和
        }
        byte[] out = new byte[2 + core.length + 1];
        out[0] = (byte) 0xFF;
        out[1] = (byte) 0xFF;
        System.arraycopy(core, 0, out, 2, core.length);
        out[out.length - 1] = check;
        return out;
    }

    /** ASCII 转字节（原版握手帧是 ASCII 字符串） */
    private static byte[] ascii(String s) {
        byte[] b = new byte[s.length()];
        for (int i = 0; i < s.length(); i++) b[i] = (byte) s.charAt(i);
        return b;
    }

    /**
     * GW20 握手帧（非加密型号，累加和校验）——最常见。
     * 原版 o82.OooO00o = {71,87,50,48,0,0} = "GW20\0\0"
     * 结果: FF FF 00 08 03 47 57 32 30 00 00 0B
     */
    public static byte[] handshakeGW20() {
        return wrapPayload(ascii("GW20\u0000\u0000"), false);
    }

    /** GW20 握手帧（加密型号，CRC8 校验） */
    public static byte[] handshakeGW20Crc() {
        return wrapPayload(ascii("GW20\u0000\u0000"), true);
    }

    /** GW10 握手帧（AFI_V5_New 型号，原版 o82.OooO0O0 = "GW10\0\x30"） */
    public static byte[] handshakeGW10() {
        return wrapPayload(new byte[]{71,87,49,48,0,48}, false);
    }

    /** 断开帧 GW21（原版 getAppDisConnected） */
    public static byte[] goodbyeGW21() {
        return wrapPayload(new byte[]{71,87,50,49,0,0}, false);
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    /** 十六进制串，便于调试显示 */
    public static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02X ", x & 0xFF));
        return s.toString().trim();
    }
}
