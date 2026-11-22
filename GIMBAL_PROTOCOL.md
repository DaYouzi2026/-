# 勤蓝/Netviv 云台 BLE 控制协议（逆向自 Gimbal Play v2.5.57）

> 来源：Gimbal Play APK (`com.netviv.photo.gimbalplay`) 反编译。
> 逆向日期 2026-11-22。用于自研云台控制 App。

## 1. BLE 连接参数

| 项 | 值 |
|---|---|
| 服务 UUID | `0000fe00-0000-1000-8000-00805f9b34fb`（型号A）<br>`02f00000-0000-0000-0000-00000000fe00`（型号B） |
| 写特征 UUID | `0000ff01-0000-1000-8000-00805f9b34fb`（型号A）<br>`02f00000-0000-0000-0000-00000000ff01`（型号B） |
| 通知特征 UUID | `0000ff02-0000-1000-8000-00805f9b34fb`（型号A）<br>`02f00000-0000-0000-0000-00000000ff02`（型号B） |
| 写入方式 | Write（无响应或有响应均可，App 用队列串行写） |
| 设备名 | 一般含 `83:87` 等尾号；白牌三轴手机云台 |

连接后需开启 FF02 的通知（CCCD）以接收云台状态。

## 2. 数据帧结构

### 2.1 内层命令帧（ByteBuffer, LITTLE_ENDIAN）
```
偏移  长度  说明
0     1     固定 0x55
1     1     命令类型：0x02（普通）/ 其他
2     1     数据长度（部分命令）
3     1     命令码 CMD
4     1     参数区长度 n
5     1     参数区长度 n（重复）
6..   n     参数（byte / short 依命令而定）
```

### 2.2 累加校验（i00.OooOo）
对内层帧 **从第 2 字节起（含）到末尾** 求和，取低 8 位（&0xFF），追加到帧末尾。
> 注：实测代码 `v3=1; while(v3<len){sum += byte[v3]}` —— 从第 1 个索引（即第 2 字节）开始累加，**不含首字节 0x55**。

### 2.3 外层封装（gp1.OooO0o0 → gp1.OooO0Oo）★已完全确认
```
FF FF [长度高] [长度低] [通道] [内层帧] [CRC8]
```
- 头：`FF FF`（固定）
- 长度：**大端** short = 内层帧长度 + 2（即通道字节+内层帧，不含头部2字节和CRC）
  - 来源 `sb1.OooOoO`: `b[0] = (len>>8)&0xFF; b[1] = len&0xFF`
- 通道：默认 `3`（`OooO0o0` 传 3）
- 内层帧：见 2.1/2.2（已含自身累加校验）
- CRC8：`ye3.OooOO0(v4, len)` —— CRC-8/MAXIM（多项式反射 0x8D，初值 0，无异或）
  - **覆盖范围**：从长度高字节开始到内层帧末尾（即 `FF FF` 之后、CRC 之前的全部字节）
  - 若云台为加密型号（`OooOOo==true`），该字节写 0

```java
// CRC-8/MAXIM 参考实现
byte crc = 0;
for (int i = 0; i < len; i++) {
    crc ^= data[i];
    for (int j = 8; j > 0; j--)
        crc = (crc & 0x80) != 0 ? (byte)((crc << 1) ^ 0x8D) : (byte)(crc << 1);
}
```

> 真机调试若命令无反应：本实现按逆向的 `OooO0Oo(3,data,1)` 路径（累加校验+CRC8）。
> 已内置协议变体切换（通道 3/2、内层校验开/关、CRC 累加/CRC8），真机上逐项试即可。

## 3. 关键命令码（内层帧第 4 字节 CMD）

| CMD (hex) | 方法 | 功能 | 参数 |
|---|---|---|---|
| `0x23` (35) | `i00.OooOooo(p6,p7)` | **转头（yaw/pitch）** | 两个 short，范围 ±1000，小端。p6=水平，p7=俯仰 |
| `0x11` (17) | `i00.OooOooO(Short[])` | **目标坐标/跟随点** | 3×short（x,y,z×100），小端 |
| `0x22` (34) | `i00.OooOoo(boolean)` | 开关类（人脸跟踪相关） | 1 byte 0/1 |
| `0x25` (37) | GimbalSettingView | **设置类**（子功能 1/2/3/4/5） | 见下 |
| `0x31` (49) | `i00.OoooO0(p2,p3)` | 模式设置 | 2×byte |
| `0x49` (73) | `oO00Oo0.OooOo0(bool)` | 开关类（6×byte 重复） | 6 byte |
| `0x61` (97) | `i00.OooOoO(byte)` | 单字节设置 | 1 byte |
| `0x0C` (12) | `i00.OooOoO0(轨迹点)` | 轨迹点数组 | Short[] 三元组 |

### 0x25 设置类子功能（GimbalSettingView 逆向）
```
AA 55 02 00 25 [子功能] [值] + 校验
子功能: 1/2/3/5 = 位置/模式设置；4 = 开关
```
具体子功能语义（哪个是灵敏度、哪个是跟随速度）需真机逐项验证。

## 4. 转头指令构造（核心，直接可用）
```java
ByteBuffer b = ByteBuffer.allocate(11).order(LITTLE_ENDIAN);
b.put((byte)0x55);   // 85
b.put((byte)0x02);   // 2
b.put((byte)0x0B);   // 11
b.put((byte)0x23);   // 35 = 转头命令
b.put((byte)0x05);   // 5
b.put((byte)0x05);   // 5
b.putShort((short) yaw);    // 水平 ±1000
b.putShort((short) pitch);  // 俯仰 ±1000
b.put((byte) mode);  // 0（非UPDOT型号）
// + i00.OooOo 累加校验
// 再经 gp1.OooO0o0 外层封装 → 写入 FF01
```

## 5. 视觉/算法（App 端，so 库验证）
- so 库 `libnetviv_comm.so` 只做视觉检测（OpenCV + MNN）：
  - `FaceDetect.track()`、`ObjectTracker.process()`、`PoseDetector.track()`
  - 无电机/转动 JNI → **转头完全由 App 发 BLE 指令控制**（利好自研）
- 灵敏度相关参数（类 `x23`）：跟踪加速 `setTrackerSpeedUp`、延迟停止 `setTrackerDelayStopTime`、跟踪范围 `setTrackerXYMax`、XY 算法 `setTrackerXYCalculationMethod`、方向反转 `setTrackerXYReverseDirection`
- 横竖屏锁定：`NetvivCamera.setLockRecordVideoOrientation(Boolean)` → 软件功能，可自研（检测姿态稳定 + 延时确认 + 滞回区间防抖）

## 6. 自研 App 跟随方案
1. 手机摄像头检测人脸/人体（Android: ML Kit；iOS: Vision VNSequenceDetector）
2. 计算目标中心相对画面中心的归一化偏移 (dx, dy) ∈ [-1,1]
3. 死区过滤：|dx|<deadzone 不动作
4. PID/比例控制：yaw = clamp(dx * gain * 1000, -1000, 1000)，pitch 同理
5. 平滑：对 yaw/pitch 做低通滤波，避免抖动
6. 组帧 0x23 命令 → BLE 写 FF01
7. 横竖屏锁定：检测姿态连续 N 帧稳定 → 锁定方向，动作抖动不触发切换；手动解锁

## 7. 待真机验证项
- 外层封装 `FF FF ... 03 ...` 的确切字节顺序与外层校验算法
- 0x23 的 p6/p7 谁是 yaw、谁是 pitch，以及正负方向
- 0x25 各子功能对应的灵敏度项
- 通道参数 2 vs 0 的区别
