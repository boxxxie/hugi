package hugi_cli

import obench "../../deps/obench/obench"

/*
Isolates `deps/obench` machine-state helpers outside `deps/obench/STABILITY.md`'s stable
package surface behind CLI-private wrappers.
*/

@(private)
_Obench_Machine_State :: obench.Machine_State
@(private)
_Obench_Machine_Note :: obench.Machine_Note

@(private, require_results)
_obench_read_machine_state :: proc(allocator := context.allocator) -> _Obench_Machine_State {
	return obench.read_machine_state(allocator)
}

@(private)
_obench_machine_state_destroy :: proc(st: ^_Obench_Machine_State, allocator := context.allocator) {
	obench.machine_state_destroy(st, allocator)
}

@(private, require_results)
_obench_machine_notes :: proc(
	st: _Obench_Machine_State,
	cores: int,
	allocator := context.temp_allocator,
) -> []_Obench_Machine_Note {
	return obench.machine_notes(st, cores, allocator)
}
