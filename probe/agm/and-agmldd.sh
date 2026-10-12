#!/system/bin/sh
exec > /data/local/tmp/and-agmldd.out 2>&1
echo "=== 哪些现成二进制链接了 libagmclient.so（可抄调用模式）==="
for b in agmplay agmcap agmcompressplay agmhostless agmvoiceui mm-audio-ftm audioadsprpcd audiodsd2pcmtest audioflacapp; do
  d=$(LD_LIBRARY_PATH=/vendor/lib64 ldd /vendor/bin/$b 2>/dev/null | grep -c 'libagmclient')
  printf '  %-20s libagmclient=%s\n' "$b" "$d"
done
echo
echo "=== libagmclient.so 的 NEEDED ==="
LD_LIBRARY_PATH=/vendor/lib64 ldd /vendor/lib64/libagmclient.so 2>&1 | head -20
echo
echo "=== libagmmixer.so 的 NEEDED ==="
LD_LIBRARY_PATH=/vendor/lib64 ldd /vendor/lib64/libagmmixer.so 2>&1 | head -20
echo DONE