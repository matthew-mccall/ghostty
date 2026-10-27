import os, time, base64
line = 'Homebrew CRT  -> => != !== == === <= >= && || :: ...  0123456789  '
os.write(1, ('\x1b[2J\x1b[H\x1b[32m' + '\r\n'.join((line*8)[:230] for _ in range(75))).encode())
# A 4x4 Kitty image exercises preservation of CPU-uploaded image textures.
pixels = bytes([255, 32, 16, 255] * 16)
os.write(1, b'\x1b[20;20H\x1b_Ga=T,f=32,s=4,v=4,c=12,r=6;' + base64.b64encode(pixels) + b'\x1b\\')
if os.environ.get('GHOSTTY_BENCH_STATIC'):
    time.sleep(120)
    raise SystemExit
for i in range(6000):
    os.write(1, ('\x1b[1;1HFrame %06d  -> => != !== == === <= >= && || :: ...' % i).encode())
    time.sleep(1/120)
