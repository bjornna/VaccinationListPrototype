#r "nuget: DIPS.Buildsystem.Core, 11.7.5"

using DIPS.Buildsystem.Core.Build;
using DIPS.Buildsystem.Core.Commands;
using DIPS.Buildsystem.Core.Tools;

PackageManager.RegisterTasks();

BuildWindow.Run(Args);



