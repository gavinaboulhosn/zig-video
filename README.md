`zig-video`

# Overview
`zig-video` is a personal project with the goal of learning about audio and video processing. This project uses FFmpeg for handling various codecs and Raylib for rendering video content.  This project also serves as a way to learn the Zig, a modern systems programming language.

# Installation
To set up zig-video, you'll need to have FFmpeg, Git LFS, and Zig 0.13.0 installed. This has only been tested on macOS, but it should work on other platforms as well.  Note: Raylib is bundled through the Zig package manager, so you don't need to install it separately.  The below instructions are for macOS.  For other platforms, you'll need to adjust the installation steps accordingly.

Follow the steps below:

1. Install FFmpeg
```bash
brew install ffmpeg
```
2. Clone the repository
```bash
git clone 
# Install Git LFS
git lfs install

# Clone the repository with Git LFS
git clone https://github.com/gavinaboulhosn/zig-video.git
cd zig-video

# Fetch the sample video file
git lfs pull
```

3. Install Zig 0.13.0
You can install Zig via your package manager, or you can give [Zigup](https://github.com/marler8997/zigup) a try.

4. Build and run the project
```bash
zig build run
```

# Features
- [x] Render video frames using FFMPEG and Raylib
- [x] Add audio playback
- [x] Synchronize audio and video
- [x] Multi-threaded audio and video decoding
- [x] Play/Pause functionality
- [ ] CLI Options
- [ ] Seeking
- [ ] Support Audio and Video Pipelines
- [ ] Render Audio FFT

