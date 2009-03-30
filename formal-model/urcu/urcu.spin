/*
 * mem.spin: Promela code to validate memory barriers with OOO memory.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *
 * Copyright (c) 2009 Mathieu Desnoyers
 */

/* Promela validation variables. */

/* specific defines "included" here */
/* DEFINES file "included" here */

/* All signal readers have same PID and uses same reader variable */
#ifdef TEST_SIGNAL_ON_WRITE
#define get_pid()	((_pid < 1) -> 0 : 1)
#elif defined(TEST_SIGNAL_ON_READ)
#define get_pid()	((_pid < 2) -> 0 : 1)
#else
#define get_pid()	(_pid)
#endif

#define get_readerid()	(get_pid())

/*
 * Each process have its own data in cache. Caches are randomly updated.
 * smp_wmb and smp_rmb forces cache updates (write and read), smp_mb forces
 * both.
 */

typedef per_proc_byte {
	byte val[NR_PROCS];
};

/* Bitfield has a maximum of 8 procs */
typedef per_proc_bit {
	byte bitfield;
};

#define DECLARE_CACHED_VAR(type, x)	\
	type mem_##x;			\
	per_proc_##type cached_##x;	\
	per_proc_bit cache_dirty_##x;

#define INIT_CACHED_VAR(x, v, j)	\
	mem_##x = v;			\
	cache_dirty_##x.bitfield = 0;	\
	j = 0;				\
	do				\
	:: j < NR_PROCS ->		\
		cached_##x.val[j] = v;	\
		j++			\
	:: j >= NR_PROCS -> break	\
	od;

#define IS_CACHE_DIRTY(x, id)	(cache_dirty_##x.bitfield & (1 << id))

#define READ_CACHED_VAR(x)	(cached_##x.val[get_pid()])

#define WRITE_CACHED_VAR(x, v)				\
	atomic {					\
		cached_##x.val[get_pid()] = v;		\
		cache_dirty_##x.bitfield =		\
			cache_dirty_##x.bitfield | (1 << get_pid());	\
	}

#define CACHE_WRITE_TO_MEM(x, id)			\
	if						\
	:: IS_CACHE_DIRTY(x, id) ->			\
		mem_##x = cached_##x.val[id];		\
		cache_dirty_##x.bitfield =		\
			cache_dirty_##x.bitfield & (~(1 << id));	\
	:: else ->					\
		skip					\
	fi;

#define CACHE_READ_FROM_MEM(x, id)	\
	if				\
	:: !IS_CACHE_DIRTY(x, id) ->	\
		cached_##x.val[id] = mem_##x;\
	:: else ->			\
		skip			\
	fi;

/*
 * May update other caches if cache is dirty, or not.
 */
#define RANDOM_CACHE_WRITE_TO_MEM(x, id)\
	if				\
	:: 1 -> CACHE_WRITE_TO_MEM(x, id);	\
	:: 1 -> skip			\
	fi;

#define RANDOM_CACHE_READ_FROM_MEM(x, id)\
	if				\
	:: 1 -> CACHE_READ_FROM_MEM(x, id);	\
	:: 1 -> skip			\
	fi;

/*
 * Remote barriers tests the scheme where a signal (or IPI) is sent to all
 * reader threads to promote their compiler barrier to a smp_mb().
 */
#ifdef REMOTE_BARRIERS

inline smp_rmb_pid(i, j)
{
	atomic {
		CACHE_READ_FROM_MEM(urcu_gp_ctr, i);
		j = 0;
		do
		:: j < NR_READERS ->
			CACHE_READ_FROM_MEM(urcu_active_readers[j], i);
			j++
		:: j >= NR_READERS -> break
		od;
		CACHE_READ_FROM_MEM(generation_ptr, i);
	}
}

inline smp_wmb_pid(i, j)
{
	atomic {
		CACHE_WRITE_TO_MEM(urcu_gp_ctr, i);
		j = 0;
		do
		:: j < NR_READERS ->
			CACHE_WRITE_TO_MEM(urcu_active_readers[j], i);
			j++
		:: j >= NR_READERS -> break
		od;
		CACHE_WRITE_TO_MEM(generation_ptr, i);
	}
}

inline smp_mb_pid(i, j)
{
	atomic {
#ifndef NO_WMB
		smp_wmb_pid(i, j);
#endif
#ifndef NO_RMB
		smp_rmb_pid(i, j);
#endif
#ifdef NO_WMB
#ifdef NO_RMB
		ooo_mem(j);
#endif
#endif
	}
}

/*
 * Readers do a simple barrier(), writers are doing a smp_mb() _and_ sending a
 * signal or IPI to have all readers execute a smp_mb.
 * We are not modeling the whole rendez-vous between readers and writers here,
 * we just let the writer update each reader's caches remotely.
 */
inline smp_mb(i, j)
{
	if
	:: get_pid() >= NR_READERS ->
		smp_mb_pid(get_pid(), j);
		i = 0;
		do
		:: i < NR_READERS ->
			smp_mb_pid(i, j);
			i++;
		:: i >= NR_READERS -> break
		od;
		smp_mb_pid(get_pid(), j);
	:: else -> skip;
	fi;
}

#else

inline smp_rmb(i, j)
{
	atomic {
		CACHE_READ_FROM_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			CACHE_READ_FROM_MEM(urcu_active_readers[i], get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		CACHE_READ_FROM_MEM(generation_ptr, get_pid());
	}
}

inline smp_wmb(i, j)
{
	atomic {
		CACHE_WRITE_TO_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			CACHE_WRITE_TO_MEM(urcu_active_readers[i], get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		CACHE_WRITE_TO_MEM(generation_ptr, get_pid());
	}
}

inline smp_mb(i, j)
{
	atomic {
#ifndef NO_WMB
		smp_wmb(i, j);
#endif
#ifndef NO_RMB
		smp_rmb(i, j);
#endif
#ifdef NO_WMB
#ifdef NO_RMB
		ooo_mem(i);
#endif
#endif
	}
}

#endif

/* Keep in sync manually with smp_rmb, wmp_wmb, ooo_mem and init() */
DECLARE_CACHED_VAR(byte, urcu_gp_ctr);
/* Note ! currently only two readers */
DECLARE_CACHED_VAR(byte, urcu_active_readers[NR_READERS]);
/* pointer generation */
DECLARE_CACHED_VAR(byte, generation_ptr);

byte last_free_gen = 0;
bit free_done = 0;
byte read_generation[NR_READERS];
bit data_access[NR_READERS];

bit write_lock = 0;

bit init_done = 0;

bit sighand_exec = 0;

inline wait_init_done()
{
	do
	:: init_done == 0 -> skip;
	:: else -> break;
	od;
}

#ifdef TEST_SIGNAL

inline wait_for_sighand_exec()
{
	sighand_exec = 0;
	do
	:: sighand_exec == 0 -> skip;
	:: else -> break;
	od;
}

#ifdef TOO_BIG_STATE_SPACE
inline wait_for_sighand_exec()
{
	sighand_exec = 0;
	do
	:: sighand_exec == 0 -> skip;
	:: else ->
		if
		:: 1 -> break;
		:: 1 -> sighand_exec = 0;
			skip;
		fi;
	od;
}
#endif

#else

inline wait_for_sighand_exec()
{
	skip;
}

#endif

#ifdef TEST_SIGNAL_ON_WRITE
/* Block on signal handler execution */
inline dispatch_sighand_write_exec()
{
	sighand_exec = 1;
	do
	:: sighand_exec == 1 ->
		skip;
	:: else ->
		break;
	od;
}

#else

inline dispatch_sighand_write_exec()
{
	skip;
}

#endif

#ifdef TEST_SIGNAL_ON_READ
/* Block on signal handler execution */
inline dispatch_sighand_read_exec()
{
	sighand_exec = 1;
	do
	:: sighand_exec == 1 ->
		skip;
	:: else ->
		break;
	od;
}

#else

inline dispatch_sighand_read_exec()
{
	skip;
}

#endif


inline ooo_mem(i)
{
	atomic {
		RANDOM_CACHE_WRITE_TO_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			RANDOM_CACHE_WRITE_TO_MEM(urcu_active_readers[i],
				get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		RANDOM_CACHE_WRITE_TO_MEM(generation_ptr, get_pid());
		RANDOM_CACHE_READ_FROM_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			RANDOM_CACHE_READ_FROM_MEM(urcu_active_readers[i],
				get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		RANDOM_CACHE_READ_FROM_MEM(generation_ptr, get_pid());
	}
}

inline wait_for_reader(tmp, tmp2, i, j)
{
	do
	:: 1 ->
		tmp2 = READ_CACHED_VAR(urcu_active_readers[tmp]);
		ooo_mem(i);
		dispatch_sighand_write_exec();
		if
		:: (tmp2 & RCU_GP_CTR_NEST_MASK)
			&& ((tmp2 ^ READ_CACHED_VAR(urcu_gp_ctr))
				& RCU_GP_CTR_BIT) ->
#ifndef GEN_ERROR_WRITER_PROGRESS
			smp_mb(i, j);
#else
			ooo_mem(i);
#endif
			dispatch_sighand_write_exec();
		:: else	->
			break;
		fi;
	od;
}

inline wait_for_quiescent_state(tmp, tmp2, i, j)
{
	tmp = 0;
	do
	:: tmp < NR_READERS ->
		wait_for_reader(tmp, tmp2, i, j);
		if
		:: (NR_READERS > 1) && (tmp < NR_READERS - 1)
			-> ooo_mem(i);
			   dispatch_sighand_write_exec();
		:: else
			-> skip;
		fi;
		tmp++
	:: tmp >= NR_READERS -> break
	od;
}

/* Model the RCU read-side critical section. */

inline urcu_one_read(i, j, nest_i, tmp, tmp2)
{
	nest_i = 0;
	do
	:: nest_i < READER_NEST_LEVEL ->
		ooo_mem(i);
		dispatch_sighand_read_exec();
		tmp = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);
		ooo_mem(i);
		dispatch_sighand_read_exec();
		if
		:: (!(tmp & RCU_GP_CTR_NEST_MASK))
			->
			tmp2 = READ_CACHED_VAR(urcu_gp_ctr);
			ooo_mem(i);
			dispatch_sighand_read_exec();
			WRITE_CACHED_VAR(urcu_active_readers[get_readerid()],
					 tmp2);
		:: else	->
			WRITE_CACHED_VAR(urcu_active_readers[get_readerid()],
					 tmp + 1);
		fi;
		smp_mb(i, j);
		dispatch_sighand_read_exec();
		nest_i++;
	:: nest_i >= READER_NEST_LEVEL -> break;
	od;

	read_generation[get_readerid()] = READ_CACHED_VAR(generation_ptr);
	data_access[get_readerid()] = 1;
	data_access[get_readerid()] = 0;

	nest_i = 0;
	do
	:: nest_i < READER_NEST_LEVEL ->
		smp_mb(i, j);
		dispatch_sighand_read_exec();
		tmp2 = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);
		ooo_mem(i);
		dispatch_sighand_read_exec();
		WRITE_CACHED_VAR(urcu_active_readers[get_readerid()], tmp2 - 1);
		nest_i++;
	:: nest_i >= READER_NEST_LEVEL -> break;
	od;
	//ooo_mem(i);
	//dispatch_sighand_read_exec();
	//smp_mc(i);	/* added */
}

active proctype urcu_reader()
{
	byte i, j, nest_i;
	byte tmp, tmp2;

	wait_init_done();

	assert(get_pid() < NR_PROCS);

end_reader:
	do
	:: 1 ->
		/*
		 * We do not test reader's progress here, because we are mainly
		 * interested in writer's progress. The reader never blocks
		 * anyway. We have to test for reader/writer's progress
		 * separately, otherwise we could think the writer is doing
		 * progress when it's blocked by an always progressing reader.
		 */
#ifdef READER_PROGRESS
		/* Only test progress of one random reader. They are all the
		 * same. */
		if
		:: get_readerid() == 0 ->
progress_reader:
			skip;
		fi;
#endif
		urcu_one_read(i, j, nest_i, tmp, tmp2);
	od;
}

#ifdef TEST_SIGNAL
/* signal handler reader */

inline urcu_one_read_sig(i, j, nest_i, tmp, tmp2)
{
	nest_i = 0;
	do
	:: nest_i < READER_NEST_LEVEL ->
		ooo_mem(i);
		tmp = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);
		ooo_mem(i);
		if
		:: (!(tmp & RCU_GP_CTR_NEST_MASK))
			->
			tmp2 = READ_CACHED_VAR(urcu_gp_ctr);
			ooo_mem(i);
			WRITE_CACHED_VAR(urcu_active_readers[get_readerid()],
					 tmp2);
		:: else	->
			WRITE_CACHED_VAR(urcu_active_readers[get_readerid()],
					 tmp + 1);
		fi;
		smp_mb(i, j);
		nest_i++;
	:: nest_i >= READER_NEST_LEVEL -> break;
	od;

	read_generation[get_readerid()] = READ_CACHED_VAR(generation_ptr);
	data_access[get_readerid()] = 1;
	data_access[get_readerid()] = 0;

	nest_i = 0;
	do
	:: nest_i < READER_NEST_LEVEL ->
		smp_mb(i, j);
		tmp2 = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);
		ooo_mem(i);
		WRITE_CACHED_VAR(urcu_active_readers[get_readerid()], tmp2 - 1);
		nest_i++;
	:: nest_i >= READER_NEST_LEVEL -> break;
	od;
	//ooo_mem(i);
	//smp_mc(i);	/* added */
}

active proctype urcu_reader_sig()
{
	byte i, j, nest_i;
	byte tmp, tmp2;

	wait_init_done();

	assert(get_pid() < NR_PROCS);

end_reader:
	do
	:: 1 ->
		wait_for_sighand_exec();
		/*
		 * We do not test reader's progress here, because we are mainly
		 * interested in writer's progress. The reader never blocks
		 * anyway. We have to test for reader/writer's progress
		 * separately, otherwise we could think the writer is doing
		 * progress when it's blocked by an always progressing reader.
		 */
#ifdef READER_PROGRESS
		/* Only test progress of one random reader. They are all the
		 * same. */
		if
		:: get_readerid() == 0 ->
progress_reader:
			skip;
		fi;
#endif
		urcu_one_read_sig(i, j, nest_i, tmp, tmp2);
	od;
}

#endif

/* Model the RCU update process. */

active proctype urcu_writer()
{
	byte i, j;
	byte tmp, tmp2;
	byte old_gen;

	wait_init_done();

	assert(get_pid() < NR_PROCS);

	do
	:: (READ_CACHED_VAR(generation_ptr) < 5) ->
#ifdef WRITER_PROGRESS
progress_writer1:
#endif
		ooo_mem(i);
		dispatch_sighand_write_exec();
		atomic {
			old_gen = READ_CACHED_VAR(generation_ptr);
			WRITE_CACHED_VAR(generation_ptr, old_gen + 1);
		}
		ooo_mem(i);
		dispatch_sighand_write_exec();

		do
		:: 1 ->
			atomic {
				if
				:: write_lock == 0 ->
					write_lock = 1;
					break;
				:: else ->
					skip;
				fi;
			}
		od;
		smp_mb(i, j);
		dispatch_sighand_write_exec();
		tmp = READ_CACHED_VAR(urcu_gp_ctr);
		ooo_mem(i);
		dispatch_sighand_write_exec();
		WRITE_CACHED_VAR(urcu_gp_ctr, tmp ^ RCU_GP_CTR_BIT);
		ooo_mem(i);
		dispatch_sighand_write_exec();
		//smp_mc(i);
		wait_for_quiescent_state(tmp, tmp2, i, j);
		//smp_mc(i);
#ifndef SINGLE_FLIP
		ooo_mem(i);
		dispatch_sighand_write_exec();
		tmp = READ_CACHED_VAR(urcu_gp_ctr);
		ooo_mem(i);
		dispatch_sighand_write_exec();
		WRITE_CACHED_VAR(urcu_gp_ctr, tmp ^ RCU_GP_CTR_BIT);
		//smp_mc(i);
		ooo_mem(i);
		dispatch_sighand_write_exec();
		wait_for_quiescent_state(tmp, tmp2, i, j);
#endif
		smp_mb(i, j);
		dispatch_sighand_write_exec();
		write_lock = 0;
		/* free-up step, e.g., kfree(). */
		atomic {
			last_free_gen = old_gen;
			free_done = 1;
		}
	:: else -> break;
	od;
	/*
	 * Given the reader loops infinitely, let the writer also busy-loop
	 * with progress here so, with weak fairness, we can test the
	 * writer's progress.
	 */
end_writer:
	do
	:: 1 ->
#ifdef WRITER_PROGRESS
progress_writer2:
#endif
		dispatch_sighand_write_exec();
	od;
}

/* Leave after the readers and writers so the pid count is ok. */
init {
	byte i, j;

	atomic {
		INIT_CACHED_VAR(urcu_gp_ctr, 1, j);
		INIT_CACHED_VAR(generation_ptr, 0, j);

		i = 0;
		do
		:: i < NR_READERS ->
			INIT_CACHED_VAR(urcu_active_readers[i], 0, j);
			read_generation[i] = 1;
			data_access[i] = 0;
			i++;
		:: i >= NR_READERS -> break
		od;
		init_done = 1;
	}
}
