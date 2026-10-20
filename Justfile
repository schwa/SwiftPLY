default:
	just --list

fuzz minutes="5":
	#!/usr/bin/env fish
	mkdir -p .build/fuzz/corpus
	swiftly run swiftc +latest -sanitize=fuzzer,address -parse-as-library -O -module-name SwiftPLY Sources/SwiftPLY/*.swift Fuzzing/PLYFuzzer.swift -o .build/fuzz/PLYFuzzer; or exit 1
	.build/fuzz/PLYFuzzer -max_total_time=(math "{{minutes}} * 60") -max_len=1048576 -print_final_stats=1 -dict=Fuzzing/PLY.dict .build/fuzz/corpus Fuzzing/Corpus Tests/SwiftPLYTests/Fixtures
