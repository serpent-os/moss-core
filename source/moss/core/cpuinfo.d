/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * moss.core.cpuinfo
 *
 * Access to CPU information via /proc/cpuinfo and to
 * kernel information via /proc/version on Linux
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module moss.core.cpuinfo;

import moss.core.c : uname, utsname;
import std.algorithm : canFind, each, fold, map, sort;
import std.array;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.parallelism : totalCPUs;
import std.range : iota;
import std.regex;
import std.stdio : File, writeln, writefln;
import std.string : fromStringz, split, strip;
import std.typecons : tuple;

/**
 * Polled once at startup
 *
 * 64-bit support is assumed a priori
 */
public final class CpuInfo
{
    /**
     * Construct new CpuInfo
     */
    this() @safe
    {
        parseISA();
        parseVersionFile();
        parseCpuinfoFile();
    }

    /**
     * Suppoted ISAs + levels
     */
    enum ISALevel : string
    {
        unknown = "unknown",
        x86_64 = "x86_64",
        x86_64_v2 = "x86_64_v2",
        x86_64_v3 = "x86_64_v3",
        x86_64_v3x = "x86_64_v3x",
    }

    /**
     * Returns: string describing Instruction Set Architecture
     */
    pure const string ISA() nothrow @nogc @safe
    {
        return _ISA;
    }

    /**
     * Supported ISA levels for rendering
     *
     * Returns: string array of supported ISA levels
     */
    pure string[] ISALevels() nothrow @nogc @safe
    {
        return _ISALevels;
    }

    /**
     * Returns: Maximum supported ISALevel
     */
    pure string ISAMaxLevel() nothrow @nogc @safe
    {
        return cast(string) _ISAMaxLevel;
    }

    /**
     * Returns: string from the contents of /proc/version
     */
    pure const string kernel() nothrow @nogc @safe
    {
        return _kernel;
    }

    /**
     * Returns: CPU model name
     */
    pure const string modelName() nothrow @nogc @safe
    {
        return _modelName;
    }

    /**
     * Returns: string of the format "cores / hwtreads"
     */
    pure const string numCoresThreads() @safe
    {
        return format!"%dc / %dt"(_numCores, _numHWThreads);
    }

private:

    /**
     * Parse ISA from machine property in utsname struct from uname(2) syscall
     */
    void parseISA() @trusted
    {
        /* need to call uname on a pointer to an initialised utsname struct */
        utsname* _utsname = new utsname;
        uname(_utsname);
        /* C strings are null-terminated */
        _ISA = cast(string) _utsname.machine.fromStringz;
    }

    /**
     * Parse /proc/version kernel version file
     */
    void parseVersionFile(immutable string versionFile = "/proc/version") @trusted
    {
        auto buffer = readText(versionFile);
        /* we expect a single line */
        if (buffer)
        {
            _kernel = buffer.strip;
        }
    }

    /**
     * Parse select fields in /proc/cpuinfo
     */
    void parseCpuinfoFile(immutable string cpuinfoFile = "/proc/cpuinfo") @trusted
    {
        /* If we can't parse /proc/cpuinfo, bailing with an exception is ok */
        auto buffer = readText(cpuinfoFile);

        /* Find first 'model name' occurence */
        auto r = ctRegex!r"model name\s+:\s+(.*)\n";
        auto m = matchFirst(buffer, r);
        enforce(m.captures[1], format!"CPU model name not listed in %s?"(cpuinfoFile));
        _modelName = m.captures[1].strip;

        /* Find first 'cpu cores' occurence */
        r = ctRegex!r"cpu cores\s+:\s+(.*)\n";
        m = matchFirst(buffer, r);
        enforce(m.captures[1],
                format!"Number of physical CPU cores not listed in %s?"(cpuinfoFile));
        _numCores = m.captures[1].strip.to!uint;

        /* Find first 'siblings' occurence */
        r = ctRegex!r"siblings\s+:\s+(.*)\n";
        m = matchFirst(buffer, r);
        enforce(m.captures[1], format!"Number of CPU H/W threads not listed in %s?"(cpuinfoFile));
        _numHWThreads = m.captures[1].strip.to!uint;

        /* Find first 'flags' occurence */
        r = ctRegex!r"flags\s+:\s+(.*)\n";
        m = matchFirst(buffer, r);
        enforce(m.captures[1], format!"CPU flags not listed in %s?"(cpuinfoFile));
        _cpuFlags = m.captures[1].strip.split;
        /* Makes for quicker searching */
        _cpuFlags.sort;

        /* parseISA() is run from the constructor */
        if (_ISA != "unknown")
        {
            /* TODO: this can be changed to a switch block later */
            if (_ISA == "x86_64")
            {
                auto result = parseISALevelsX86_64();
                _ISAMaxLevel = result.ISAMaxLevel;
                _ISALevels = result.ISALevels;
            }
        }
    }

    /**
     * Returns: tuple(ISAMaxLevel, ISALevels)
     */
    auto parseISALevelsX86_64()
    {
        /* If we've reached this point, it's because _ISA == "x86_64" */
        enforce(_ISA = "x86_64", "_ISA != x86_64? Did you remember to call parseCpuinfoFile before calling parseISALevelsX86?");

        string[] ISALevels = [cast(string) ISALevel.x86_64];
        auto ISAMaxLevel = ISALevel.x86_64;

        /* Higher x86_64 ISA Levels are extensions of lower ISA Levels */
        if (x86_64_v2)
        {
            ISALevels ~= cast(string) ISALevel.x86_64_v2;
            ISAMaxLevel = ISALevel.x86_64_v2;

            if (x86_64_v3)
            {
                ISALevels ~= cast(string) ISALevel.x86_64_v3;
                ISAMaxLevel = ISALevel.x86_64_v3;

                if (x86_64_v3x)
                {
                    ISALevels ~= cast(string) ISALevel.x86_64_v3x;
                    ISAMaxLevel = ISALevel.x86_64_v3x;
                }
            }
        }
        return tuple!("ISAMaxLevel", "ISALevels")(ISAMaxLevel, ISALevels);
    }

    /* Note that 'pni' is 'prescott new instructions' aka SSE3 */
    static immutable _x86_64_v2 = [
        "cx16", "lahf_lm", "popcnt", "pni", "ssse3", "sse4_1", "sse4_2"
    ];

    /**
     * Returns: bool indicating support for the x86_64-v2 psABI
     */
    pure const bool x86_64_v2() @safe
    {
        auto supported = _x86_64_v2.map!((s) => canFind(_cpuFlags, s));
        return supported.fold!((a, b) => a && b);
    }

    /* lzcnt is part of abm, osxsave is xsave (CBR4:18) */
    static immutable _x86_64_v3 = [
        "abm", "avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "movbe", "xsave"
    ];

    /**
     * Returns: bool indicating support for the x86_64-v3 psABI
     *
     * Note: This function does not check for x86_64-v2 psABI support
     */
    pure const bool x86_64_v3() @safe
    {
        auto supported = _x86_64_v3.map!((s) => canFind(_cpuFlags, s));
        return supported.fold!((a, b) => a && b);
    }

    /* Serpent OS x86_64-v3 extended instruction set profile for improved performance */
    static immutable _x86_64_v3x = [
        "aes", "fsgsbase", "pclmulqdq", "rdrand", "xsaveopt"
    ];

    /**
     * Returns: bool indicating support for the x86_64-v3x extended x86_64-v3 psABI?
     *
     * Note: This function does not check for x86_64-v2 nor x86_64-v3 psABI support
     */
    pure const bool x86_64_v3x() @safe
    {
        auto supported = _x86_64_v3x.map!((s) => canFind(_cpuFlags, s));
        return supported.fold!((a, b) => a && b);
    }

    string _ISA = "unknown";
    ISALevel _ISAMaxLevel = ISALevel.unknown;
    string[] _ISALevels = [];
    string[] _cpuFlags = [];
    string _kernel = "Linux version unknown";
    string _modelName = "unknown";
    uint _numCores = 0;
    uint _numHWThreads = 0;
}
@("Test CPU ISA detection")
private unittest
{
    auto cpu = new CpuInfo;
    /* FIXME: This is obviously sketchy, but let's leave it in for now */
    assert(cpu.ISA == "x86_64");
    writefln!"Currently running on CPU: %s (%s)\n supporting ISA Levels (max): %s (%s)\non top of kernel:\n%s"(
        cpu.modelName, cpu.ISA, cpu.ISALevels, cpu.ISAMaxLevel, cpu.kernel);
}


/**
 * CPU Frequency information (polled frequently)
 */
public final class CpufreqInfo
{
    /**
     * Construct new CpuInfo
     */
    this() @safe
    {
        /* this is the number of available hardware threads reported by the OS */
        numHWThreads = totalCPUs();
        _frequencies.reserve(numHWThreads);
        _frequencies.length = numHWThreads;

        refresh();
    }

    /**
     * Refresh data
     */
    void refresh() @safe
    {
        /* TODO: is it ok to bail if /sys isn't mounted? */
        iota(0, numHWThreads).map!((i) => tuple!("cpu", "freq")(i,
                readText(format!"/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq"(i))
                .strip.to!double))
            .each!((cpu, freq) => _frequencies[cpu] = freq);
    }

    /**
     * Return the current frequencies
     */
    @property auto frequencies() @safe
    {
        return _frequencies[0 .. numHWThreads];
    }

    uint numHWThreads = 0;

private:
    double[] _frequencies;
}

public final class LoadavgInfo
{
    /**
     *  Running Average
     *   1m   5m   15m  runnable/total newestPID
     *  "0.52 0.51 0.63 1/2505 1020465"
     */
    this() @safe
    {
        refresh();
    }

    void refresh(immutable string loadavgFile = "/proc/loadavg") @trusted
    {
        auto buffer = readText(loadavgFile);
        auto fields = buffer.strip.split;
        _jobAvg1Minute = fields[0].to!float;
        _jobAvg5Minutes = fields[1].to!float;
        _jobAvg15Minutes = fields[2].to!float;
        _schedulingEntities = fields[3].split("/").map!((i) => i.to!ulong).array;
        _newestPID = fields[4].to!long;
    }

    /**
     * Allow the consumer to use the raw floats
     *
     * Returns: float array [loadavg1minute, loadavg5minutes, loadavg15minutes]
     */
    float[3] loadAvg() @safe
    {
        return [_jobAvg1Minute, _jobAvg5Minutes, _jobAvg15Minutes];
    }

private:
    float _jobAvg1Minute = 0.0;
    float _jobAvg5Minutes = 0.0;
    float _jobAvg15Minutes = 0.0;
    /* [0] is runnableEntities, [1] is totalEntities known to the Linux scheduler */
    ulong[2] _schedulingEntities = [0, 0];
    /* pid_t (3) mentions needing signed long */
    long _newestPID = 0;
}