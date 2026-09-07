# ProRes Pipeline Test

The test sequence is located at:

```text
/Users/zane/Movies/26-09-06/tl
```

Because available disk space is limited and ProRes 422 HQ masters are large,
this test renders at 1080p rather than 4K.

## Render

```sh
cd /Users/zane/Developer/gopro-timelapse

swift run -c release gopro-timelapse \
  --input /Users/zane/Movies/26-09-06/tl \
  --source gpr \
  --fps 30 \
  --width 1920 \
  --jobs 4 \
  --denoise 0.7 \
  --codec hevc \
  --encoder videotoolbox \
  --bitrate 20 \
  --ffmpeg /opt/homebrew/bin/ffmpeg \
  --overwrite \
  --output /Users/zane/Movies/26-09-06/tl/timelapse-prores-test.mp4
```

The render creates:

```text
/Users/zane/Movies/26-09-06/tl/timelapse-prores-test.prores.mov
/Users/zane/Movies/26-09-06/tl/timelapse-prores-test.mp4
```

The first file should be a 10-bit ProRes 422 HQ master. The second should be an
HEVC Main 10 delivery file.

## Verify the ProRes master

```sh
/opt/homebrew/bin/ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=codec_name,profile,pix_fmt,width,height \
  -of default=nw=1 \
  /Users/zane/Movies/26-09-06/tl/timelapse-prores-test.prores.mov
```

Expected key values:

```text
codec_name=prores
profile=HQ
pix_fmt=yuv422p10le
width=1920
```

## Verify the HEVC delivery file

```sh
/opt/homebrew/bin/ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=codec_name,profile,pix_fmt,width,height \
  -of default=nw=1 \
  /Users/zane/Movies/26-09-06/tl/timelapse-prores-test.mp4
```

Expected key values:

```text
codec_name=hevc
profile=Main 10
pix_fmt=yuv420p10le
width=1920
```
