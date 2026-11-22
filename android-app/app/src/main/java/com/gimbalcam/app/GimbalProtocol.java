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

    /** 外层封装: FF FF [lenHi][lenLo][channel][inner][crc/累加] */
    public static byte[] wrap(byte[] inner) {
        int coreLen = inner.length + 1;          // 通道 + 内层帧
        byte[] core = new byte[2 + coreLen];     // [lenHi][lenLo][channel][inner...]
        core[0] = (byte) ((coreLen >> 8) & 0xFF);
        core[1] = (byte) (coreLen & 0xFF);
        core[2] = (byte) channel;
        System.arraycopy(inner, 0, core, 3, inner.length);

        byte check;
        if (outerCrc) {
            check = crc8(core, core.length);
        } else {
            int sum = 0;
            for (byte b : core) sum += (b & 0xFF);
            check = (byte) (sum & 0xFF);
        }

        byte[] out = new byte[2 + core.length + 1];
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
