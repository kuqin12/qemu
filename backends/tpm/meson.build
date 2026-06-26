if have_tpm
  system_ss.add(files('tpm_backend.c'))
  system_ss.add(files('tpm_util.c'))
  system_ss.add(when: 'CONFIG_TPM_MSSIM', if_true: files('tpm_mssim.c'))

  # The passthrough and swtpm 'emulator' backends rely on POSIX-only facilities.
  if host_os != 'windows'
    system_ss.add(when: 'CONFIG_TPM_PASSTHROUGH', if_true: files('tpm_passthrough.c'))
    system_ss.add(when: 'CONFIG_TPM_EMULATOR', if_true: files('tpm_emulator.c'))
  endif
endif
