#include <stdint.h>
#include <stddef.h>
// All strings are UTF-8. Start copies its input. Poll results must be freed.
int32_t solo_start(const char *configuration_json);
char *solo_poll(void);
void solo_string_free(char *value);
void solo_cancel(void);
int32_t solo_is_running(void);
int32_t solo_submit_command(const char *command_json);
// A capture is consumed once by its ID. Free only with this function and length.
uint8_t *solo_take_frame(const char *frame_id, size_t *length);
void solo_frame_free(uint8_t *bytes, size_t length);

#include "ScriptEngine/SoloScript.h"
