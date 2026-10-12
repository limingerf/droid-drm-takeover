#!/system/bin/sh
exec > /data/local/tmp/agmprobe3.out 2>&1
chmod 755 /data/local/tmp/agmprobe
LIB=/vendor/lib64/libagmclient.so
logcat -c 2>/dev/null
echo "########## STEP=3  AIF 全表（含 aif_id）##########"
STEP=3 timeout 40 /data/local/tmp/agmprobe $LIB
echo
echo "########## STEP=4  TAG=0 ##########"
STEP=4 TAG=0 timeout 40 /data/local/tmp/agmprobe $LIB
echo
echo "########## STEP=4  TAG=1 ##########"
STEP=4 TAG=1 timeout 40 /data/local/tmp/agmprobe $LIB
echo
echo "########## 设备侧 AGM 服务日志 ##########"
logcat -d -b all 2>/dev/null | grep -iE 'AGM:' | tail -20
echo DONE