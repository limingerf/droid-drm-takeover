#!/system/bin/sh
exec > /data/local/tmp/agmprobe4.out 2>&1
chmod 755 /data/local/tmp/agmprobe
logcat -c 2>/dev/null
echo "########## STEP=5  先 aif_connect 再 session_open ##########"
STEP=5 timeout 60 /data/local/tmp/agmprobe /vendor/lib64/libagmclient.so
echo
echo "########## 设备侧 AGM 服务日志 ##########"
logcat -d -b all 2>/dev/null | grep -iE 'AGM:' | tail -25
echo DONE