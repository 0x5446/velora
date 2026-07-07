# Demo GIF 拍摄手册

目标：README 顶部 10 秒左右的演示 GIF（`docs/assets/demo.gif`，en + zh-CN 两个 README 同步引用）。
两幕结构，展示 Velora 的两个核心卖点：语气词净化上屏、本地翻译。

## 两幕脚本（已彩排验证）

| 幕 | 模式 | 台词 | 验证点 |
|---|---|---|---|
| 1 | 听写 | "Um, so, remind me to, uh, send the weekly report to the team before five p m." | um/uh 被剥除；`five p m` → `5 PM`（ITN） |
| 2 | 翻译 | "所有的语音识别和翻译都在这台电脑上完成，完全不需要联网。" | 逐字转写无误，英文译文上屏 |

弃案记录：句内中英重度混杂 + 美音语气词会让 ASR 翻车（彩排实测），
所以"中英混合"改为两幕分别展示，不做单句混杂。

GIF 无声，画面下方叠"🎙 说话内容"字幕条，让"说了什么 → 上屏了什么"的对比可见。

## 配音

用 `scripts/demo_voiceover.sh` 重新生成（Cartesia sonic-2，Skylar 美式女声）。
需要环境变量 `CARTESIA_API_KEY`，key 不入库。

生成后先做数字域检查（直接把 wav 喂给 SenseVoice，绕过声学环节）：

```bash
cd Models/sensevoice
.venv/bin/python -c "
import sherpa_onnx, soundfile as sf
rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(model='model.int8.onnx', tokens='tokens.txt', language='auto', use_itn=True)
for f in ['/tmp/velora-demo/beat1en.wav','/tmp/velora-demo/beat2.wav']:
    audio, sr = sf.read(f, dtype='float32')
    s = rec.create_stream(); s.accept_waveform(sr, audio)
    rec.decode_stream(s)
    print(f.split('/')[-1], '->', s.result.text)
"
```

## 声学链路复测（拍摄前必做）

外放 wav → MacBook 麦克风实拾 → 转写，确认空气路径质量：

```bash
(sleep 1; afplay /tmp/velora-demo/beat1en.wav; sleep 0.6; afplay /tmp/velora-demo/beat2.wav) &
ffmpeg -y -f avfoundation -i ":1" -t 14 -ar 16000 -ac 1 /tmp/velora-demo/airpath.wav
ffmpeg -i /tmp/velora-demo/airpath.wav -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
```

已知隐患：上次锁屏前的彩排拾音偏弱。若 mean_volume 明显低，
检查控制中心 Mic Mode 是否被切到 Voice Isolation。

音量：拍摄时临时 `osascript -e "set volume output volume 45"`，拍完恢复用户原音量（上次为 25）。

## 触发与捕捉

不要合成 Fn 键（不可靠），用 AppleScript 点 Velora 菜单栏项触发；
菜单项标题随状态动态变化（`开始听写（Fn）` / `开始翻译（Fn ⇧）` → 录音中变为 `完成并上屏（Fn）`）：

```bash
VELORA_PID=$(pgrep -x Velora)
osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $VELORA_PID)
        click menu bar item 1 of menu bar 2
        delay 0.3
        click menu item \"开始翻译（Fn ⇧）\" of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell"
```

确认面板窗口号（用于单窗截图/取景验证）：

```bash
python3 -c "
import Quartz
wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerPID') == $VELORA_PID and w.get('kCGWindowBounds')['Height'] > 250:
        print(w.get('kCGWindowNumber'))
"
```

## 拍摄流程

1. 桌面垫深色背景板（全屏无边框深色窗口即可，任何全屏深色图片/窗口都行）
2. 打开 TextEdit 新文档作为上屏目标，光标就位
3. 开始录屏：`screencapture -v -R<x,y,w,h> demo.mov`（区域框住 TextEdit + HUD + 字幕条位置）
4. 第一幕：菜单触发听写 → `afplay beat1en.wav` → 菜单"完成并上屏" → 等结果上屏
5. 停顿 ~1s，第二幕：菜单触发翻译 → `afplay beat2.wav` → 完成 → 确认卡片上屏译文
6. 停止录屏，恢复音量

## 转 GIF

ffmpeg 两步调色板法，目标：≤10s、宽 800px、体积 < 5MB：

```bash
ffmpeg -i demo.mov -vf "fps=12,scale=800:-1:flags=lanczos,palettegen" palette.png
ffmpeg -i demo.mov -i palette.png -filter_complex "fps=12,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse" docs/assets/demo.gif
```

字幕条可在录制前就以置顶小窗形式摆在画面内（比后期 drawtext 省事，且中英文字体都由系统渲染）。
