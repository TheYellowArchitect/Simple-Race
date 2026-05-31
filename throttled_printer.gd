class_name ThrottledPrinter
extends RefCounted

var _last_print_time: int = -1000 # Initialize so it prints immediately on the first call
var interval_ms: int = 1000 # 1 second in milliseconds

func print_throttled(value: Variant) -> void:
	var current_time = Time.get_ticks_msec()
	
	if current_time - _last_print_time >= interval_ms:
		# Convert milliseconds to seconds and format to 3 decimal places
		var seconds: float = current_time / 1000.0
		var time_str: String = "%.3f" % seconds
		
		# Print the formatted output
		print("%s: [%s]" % [time_str, str(value)])
		
		_last_print_time = current_time
