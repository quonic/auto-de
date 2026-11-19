package server

// Desktop shell hooks (taskbar, decorations, start menu). Filled in by milestone 4.

// Called after every pointer motion.
shell_pointer_moved :: proc() {}

// Called on button press/release before clients see it. Return true to consume.
shell_handle_button :: proc(button: u32, pressed: bool) -> bool {
	return false
}
