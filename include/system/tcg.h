/*
 * QEMU TCG support
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

/* header to be included in non-TCG-specific code */

#ifndef SYSTEM_TCG_H
#define SYSTEM_TCG_H

#include "qemu/typedefs.h"

#ifdef CONFIG_TCG
extern bool tcg_allowed;
extern __thread bool tcg_secondary_active;
#define tcg_enabled() (tcg_allowed || tcg_secondary_active)
bool tcg_init_secondary(void);
bool tcg_secondary_cpu_realize(CPUState *cpu, Error **errp);
void tcg_secondary_cpu_unrealize(CPUState *cpu);
void tcg_secondary_cpu_thread_init(CPUState *cpu);
void tcg_secondary_cpu_thread_destroy(void);
int tcg_secondary_cpu_exec(CPUState *cpu);
#else
#define tcg_enabled() 0
static inline bool tcg_init_secondary(void)
{
	return false;
}
static inline bool tcg_secondary_cpu_realize(CPUState *cpu, Error **errp)
{
	return false;
}
static inline void tcg_secondary_cpu_unrealize(CPUState *cpu)
{
}
static inline void tcg_secondary_cpu_thread_init(CPUState *cpu)
{
}
static inline void tcg_secondary_cpu_thread_destroy(void)
{
}
static inline int tcg_secondary_cpu_exec(CPUState *cpu)
{
	return -1;
}
#endif

/**
 * qemu_tcg_mttcg_enabled:
 * Check whether we are running MultiThread TCG or not.
 *
 * Returns: %true if we are in MTTCG mode %false otherwise.
 */
bool qemu_tcg_mttcg_enabled(void);

#endif
