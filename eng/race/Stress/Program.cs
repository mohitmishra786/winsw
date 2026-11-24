using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using WinSW.Util;

// Same pattern as WrapperService: a monitor thread waits for exit and disposes the
// Process, while the stop thread calls StopProcessTree (parent first, the default).
int iterations = int.Parse(args[0]);
if (args.Length > 1 && args[1] == "direct")
{
    // Read StartTime on one thread while another thread disposes the same Process.
    var target = Process.Start(new ProcessStartInfo("ping.exe", "-n 100000 127.0.0.1") { UseShellExecute = false, RedirectStandardOutput = true });
    var counts = new Dictionary<string, int>();
    for (int i = 0; i < iterations; i++)
    {
        var q = Process.GetProcessById(target.Id);
        _ = q.Handle;
        var go = new ManualResetEventSlim();
        string result = "no exception";
        var reader = new Thread(() =>
        {
            go.Set();
            try { while (true) { _ = q.StartTime; } }
            catch (Exception e) { result = e.GetType().Name + ": " + e.Message; }
        });
        reader.Start();
        go.Wait();
        Thread.SpinWait(i % 2000);
        q.Dispose();
        reader.Join();
        counts[result] = counts.TryGetValue(result, out int c) ? c + 1 : 1;
    }
    target.Kill();
    foreach (var kv in counts) Console.WriteLine($"{kv.Value}x {kv.Key}");
    return;
}
var errors = new Dictionary<string, int>();
for (int i = 0; i < iterations; i++)
{
    var p = new Process();
    p.StartInfo = new ProcessStartInfo("ping.exe", "-n 1000 127.0.0.1") { UseShellExecute = false, RedirectStandardOutput = true };
    p.Start();
    p.BeginOutputReadLine();
    var monitor = new Thread(() => { p.WaitForExit(); p.Dispose(); });
    monitor.Start();
    Thread.Sleep(50);
    try
    {
        ProcessHelper.StopProcessTree(p, TimeSpan.FromSeconds(5), true);
    }
    catch (Exception e)
    {
        string key = e.GetType().Name + ": " + e.Message + " @ " + e.StackTrace.Split('\n')[0].Trim();
        errors[key] = errors.TryGetValue(key, out int n) ? n + 1 : 1;
    }
    monitor.Join();
}
int total = 0;
foreach (var kv in errors) { Console.WriteLine($"{kv.Value}x {kv.Key}"); total += kv.Value; }
Console.WriteLine($"RESULT {total}/{iterations} stops threw");
