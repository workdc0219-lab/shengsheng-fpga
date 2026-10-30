# 声声：单麦师生双板协同训练系统

基于两块安路 EG4S20BG256 FPGA，实现 HDMI 多媒体显示、单麦角色切换、声音特征分析和师生双屏交互。学生端提供声调爬山、气球、音量小火车、看图跟读和自由探索；教师端显示示范/跟读曲线与训练结果。

## 工程与版本

| 目录 | 内容 |
|---|---|
| `01_source/student_B/board_b` | 学生端 RTL、约束与原构建脚本 |
| `01_source/teacher_A/board_a` | 教师端 RTL、约束与原构建脚本 |
| `02_bitstreams` | 实际固化配对的原始位流 |
| `03_timing` | 配对版本时序与资源报告 |
| `05_build_support/student_impl` | 学生端封存实现数据库、网表、配置数据和导出工具 |
| `06_media_reference` | FAT32 TF 卡图片示例 |

学生端位流 SHA256：`3BFB9883867FB6C69A715D842745E3B474EB3E545ACEE3A4226CDAA41248EDA6`。

教师端位流 SHA256：`C9650B431325012498D52A917820F9C726D90FB49F02EF1E0FDEB924E536C4AF`。

完整文件身份以 `MANIFEST.json` 和 `SHA256SUMS.txt` 为准。两侧附带的另一板目录仅为协议生成器需要的契约镜像。

## 环境

- Windows，Python 3.9 或以上，Windows PowerShell。
- Tang Dynasty 6.2.168116，安装到 `C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116`，包含 EG4S20BG256 设备库。
- 教师端原严格构建脚本核验 `C:/Windows/Fonts/Dengb.ttf`。已生成的字模 ROM 在包内，正常构建不需要重新生成字模。
- 运行仿真需 Icarus Verilog，默认 `E:/Verilog/iverilog/bin/iverilog.exe`；可通过 `--iverilog` 指定其他安装路径。
- 厂商加密 IP 与原版权署名保留，需使用相应厂商工具。

建议将 RAR 解压到较短、无空格的英文目录。以下命令均在解压后的根目录执行，不需要原开发电脑上的历史工程。

## 统一入口

```powershell
python BUILD.py check
python BUILD.py test
python BUILD.py teacher
python BUILD.py student
```

`check` 校验文件清单、163 项认证构建输入和两端原始位流。

`test` 执行包内完整提供的 7 项功能仿真：小火车按键开始、游戏流程、单麦游戏、教师示范流程、总结页、物理按键流程及教师词卡/串口显示。它不依赖旧版负对照源码。

`teacher` 将教师工程复制到 `work/teacher/`，使用原严格包装脚本与固定 seed 1 完成综合、布局布线、位流生成、时序及 TMDS 检查，输出位于 `work/teacher/teacher_A/board_a/output/`。

`student` 在 `work/student/` 校验并展开封存材料，从指定 A793 数据库导出位流，随后将导出的 fuse 配置数据与原配置逐位比较。输出位于 `work/student/student_impl/work/export/`。这一入口复现已封存的学生实现，不重新综合或布线。

```powershell
# 顺序执行教师完整构建与学生封存数据库导出
python BUILD.py all

# 自定义仿真器安装位置
python BUILD.py test --iverilog D:/iverilog/bin/iverilog.exe
```

所有新输出写入 `work/`，不覆盖 `02_bitstreams`。同一输出目录已存在时入口拒绝覆盖；需要再次执行时另解压一份。运行记录在各输出目录的 `result.json`。上述入口均不调用下载器。

## 历史脚本与实现边界

`archive_recipes` 以及各板 `sim/run_*` 原脚本作为实现资料保留；其中旧版负对照、完整历史回归或分段路由流程可能引用旧目录。提交包的可执行入口使用根目录 `BUILD.py`，无需调用这些历史入口。

学生普通 `run_td.ps1` 的重新布局结果不能当作已封存数据库的等价替代。重新生成的位流是否与原文件逐字节一致，由运行记录明确给出；配置数据比较与位流文件哈希是不同检查。新构建产物不自动替换固化版本。

## 接线与交互

单麦接教师端，两板 UART TX/RX 交叉连接并共地；各端连接独立 HDMI 显示器。引脚以各板 `constraints/*.adc` 为准。两板型号相同，下载时须核对角色和位流。

学生端 TF 卡采用 FAT32，根目录存放 `PIC1.BMP` 至 `PIC4.BMP`。随包图片为 640×480、24 位未压缩 BMP 的兼容示例，背景旋律由 RTL 合成。

学生端长按 KEY3 切换训练模式。音量小火车短按 KEY2 开始、短按 KEY3 回待机；看图跟读四词为 māo 猫、yú 鱼、gǒu 狗、tù 兔，声调爬山保留 ma 四声。

技术报告在赛事系统单独提交。本项目提供发声训练的可视化辅助，不进行词语识别或医学诊断。

## 构建核验

独立解压件已完成教师端固定 seed 1 全流程构建及原严格门禁、学生端封存数据库导出和 7 项功能仿真。学生导出的 fuse 文件与原配置逐字节一致（4,900,028 个配置位）。两端新生成 bit 文件的 SHA256 与随包固化位流不同，随包位流仍保留原件；核验数值见 `BUILD_VALIDATION.json`。

项目仓库：https://github.com/workdc0219-lab/shengsheng-fpga
