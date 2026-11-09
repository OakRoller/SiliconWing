# objs.mk: wrapper for NVIDIA's src/nvidia and src/nvidia-modeset Makefiles that builds ONLY the object files.
# The upstream "all" target links with GNU ld -r and objcopy, which macOS does not have; the kext links the
# objects as a static library instead. Use: make -C <ogkm>/src/nvidia -f <this file> objs TARGET_OS=Darwin ...
include Makefile
# nvidia-modeset embeds its shader blobs with `ld -r -b binary`; the kext carries them as nvkms_shaders.cpp
# (build/arm64/gen_shaders.py) instead. The NVID string rule still lists them, so give them empty objects.
ifneq ($(strip $(SHADER_OBJS)),)
$(SHADER_OBJS):
	@$(MKDIR) $(OUTPUTDIR)
	$(CC) $(EXTRA_CFLAGS) -x c -c /dev/null -o $@
endif
.PHONY: objs objlist
objs: $(OBJS)
objlist:
	@echo $(filter-out %_shaders.xz.o,$(OBJS))
