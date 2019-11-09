echo "usage: ./BUILD_BIN_GUICREATESWTOKEN_FOR_MAC.sh"
	cp -f create_sw_token_mac create_sw_token 
	cp -f create_user_license_request_mac create_user_license_request
#	cp -f libls11sw2016_64.so libls11sw2016.so 
	cp -f p11conf_mac p11conf

../../WRAP_MAC/tclexecomp64_v.1.0.3 guicreate_sw_tcl.tcl create_sw_token create_user_license_request libls11sw2016.dylib p11conf  my_orel_380x150.png  -forcewrap -w  ../../WRAP_MAC/tclexecomp64.mac_v.1.0.3 -o guicreate_sw_token_mac

exit
