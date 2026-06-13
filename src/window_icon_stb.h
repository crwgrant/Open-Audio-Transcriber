#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned char stbi_uc;

stbi_uc *stbi_load_from_memory(
    const stbi_uc *buffer,
    int len,
    int *x,
    int *y,
    int *channels_in_file,
    int desired_channels);

void stbi_image_free(void *retval_from_stbi_load);

#ifdef __cplusplus
}
#endif
