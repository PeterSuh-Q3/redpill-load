for model in `cat models`
do 
echo "modify config.json on $model"
value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep os.sha256|awk '{print $1}'`
jsonfile=$(jq ".os.sha256=\"$value\"" $model/7.1.1-42962/config.json) 
echo $jsonfile | jq . > $model/7.1.1-42962/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.zlinux.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.zlinux.sha256=\"$value\"" $model/7.1.1-42962/config.json) 
echo $jsonfile | jq . > $model/7.1.1-42962/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.ramdisk.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.ramdisk.sha256=\"$value\"" $model/7.1.1-42962/config.json) 
echo $jsonfile | jq . > $model/7.1.1-42962/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.vmlinux.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.vmlinux.sha256=\"$value\"" $model/7.1.1-42962/config.json) 
echo $jsonfile | jq . > $model/7.1.1-42962/config.json

done 

for model in `cat models`
do 
echo "rename bsp file on $model"
remodel=$(echo "$model" | sed 's/DS//' | sed 's/RS//' | sed 's/+/p/' | sed 's/DVA/dva/' | sed 's/FS/fs/' | sed 's/SA/sa/' )
echo "$remodel"
cp _common/kernel-bs-fb-patch-for-all/zImage-001-${model}-42962-ramdisk-and-flag-NOP.bsp $model/7.1.1-42962/zImage-001-${remodel}-42962-ramdisk-and-flag-NOP.bsp

done
