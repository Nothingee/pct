@echo off
rem ============================================================
rem  【DEBUG 版】重点修复第 236 行之后的逻辑
rem  1) printui /if 返回后打印队列可能尚未就绪，需等待并校验
rem  2) Win11 下 printui /n ... /y 不可靠，改为多方式设置默认并校验
rem  3) Win11 24H2 已移除 wmic，改用 PowerShell/注册表
rem  4) 原 choice + if errorlevel 2 的异常退出：choice 无控制台时返回 255，
rem     改回 choice 交互（保留 10 秒倒计时），但精确判断 1/2，异常值兜底。

rem  运行日志：与本脚本同目录的 printer_log.log（无异常时自动删除）
rem ============================================================
setlocal enabledelayedexpansion
rem 强制使用 GBK 代码页，避免 Win11 开启 UTF-8 后中文乱码
chcp 936 >nul 2>&1
pushd "%~dp0"
TITLE 打印机连接工具-如有连接失败和异常请联系管理员

set "LOG=%~dp0printer_log.log"
rem 每次运行前清空日志，保证日志只记录本次运行
if exist "%LOG%" del /f /q "%LOG%" >nul 2>&1
set "PCT_ERR=0"
call :log "==================== 启动 %DATE% %TIME% ===================="
call :log "脚本路径：%~f0"

rem exit /b 错误码：0代表正常结束，1代表异常结束

rem ============================================
rem  【脚本管理员权限验证】
rem  Win11 24H2 起 VBScript 默认被移除/禁用，
rem  原来的 Getadmin.vbs 提权方式可能直接失败，
rem  失败后父窗口执行 Exit /b 就表现为“一闪而退”。
rem  这里改用 PowerShell Start-Process -Verb RunAs 提权。
rem ============================================
fltmc >nul 2>&1
if not errorlevel 1 goto :admin_ok

call :log "当前不是管理员权限，准备提权"
if /i "%~1"=="--elevated" (
    echo.
    echo [错误] 已尝试提权，但仍然没有管理员权限。
    echo 请右键选择“以管理员身份运行”，或联系 IT 管理员。
    call :log "已带 --elevated 参数但仍非管理员，退出"
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "!PS!" (
    echo.
    echo [错误] 未找到 PowerShell，无法自动提权。
    echo 请右键选择“以管理员身份运行”。
    call :log "找不到 powershell.exe，无法提权"
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)

call :log "使用 PowerShell 请求提权"
"!PS!" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -WorkingDirectory '%~dp0' -Verb RunAs" >>"%LOG%" 2>&1
if errorlevel 1 (
    echo.
    echo [提示] 提权请求被取消，或提权失败。
    echo 请右键选择“以管理员身份运行”后重试。
    call :log "PowerShell 提权失败，errorlevel=!errorlevel!"
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)
call :log "已请求提权，父窗口正常退出"
exit /b 0

:admin_ok
call :log "已获得管理员权限"

rem ============================================
rem  【对于Win11的操作前置条件处理】
rem ============================================
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
rem 禁用 SMB 客户端签名要求
"!PS!" -NoProfile -Command "Set-SmbClientConfiguration -RequireSecuritySignature $false -Force" >nul 2>&1
rem 启用不安全的来宾登录
"!PS!" -NoProfile -Command "Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force" >nul 2>&1
call :log "SMB 客户端前置设置已尝试执行"

rem ============================================
rem  【关闭“让 Windows 管理我的默认打印机”】
rem  必须在设置默认打印机之前就写入，否则 Win10/11 可能忽略设置。
rem ============================================
REG ADD "HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v "LegacyDefaultPrinterMode" /t REG_DWORD /d "1" /f >nul 2>&1
call :log "LegacyDefaultPrinterMode 已设置为 1"

rem ============================================
rem  【打印管理脚本目录】
rem  原脚本写死 zh-CN，非中文系统或新系统可能不存在，
rem  这里自动探测实际存在的目录。
rem ============================================
set "PRN_SCRIPTS=%SystemRoot%\System32\Printing_Admin_Scripts\zh-CN"
if not exist "%PRN_SCRIPTS%\prnport.vbs" set "PRN_SCRIPTS=%SystemRoot%\System32\Printing_Admin_Scripts\en-US"
if not exist "%PRN_SCRIPTS%\prnport.vbs" (
    for /d %%d in ("%SystemRoot%\System32\Printing_Admin_Scripts\*") do (
        if exist "%%d\prnport.vbs" set "PRN_SCRIPTS=%%d"
    )
)
call :log "打印管理脚本目录：%PRN_SCRIPTS%"

rem ============================================
rem  【共享服务器IP地址】
rem ============================================
set "SRV_IP=192.168.7.230"

rem ============================================
rem  【配置文件】- 型号定义与打印机列表均从共享 INI 文件在线读取
rem  文件必须存为 ANSI/GBK 编码，且换行必须为 Windows CRLF
rem  文件使用 INI 区段组织：
rem    [MODELS]   型号定义区，每行格式：型号标签=驱动文件子路径|驱动型号名称
rem    [PRINTERS] 打印机信息区，每行格式：选择名=IP地址/Port|型号标签
rem  以分号 ; 开头的行视为注释，空行会被忽略
rem ============================================
set "CFGFILE=\\%SRV_IP%\shared\打印机驱动\Windows\printers.ini"

rem ============================================
rem  【驱动目录父路径】
rem   路径结尾最后一个\斜杠不能少！！！！
rem ============================================
set "DRV_PATH=\\%SRV_IP%\shared\打印机驱动\Windows\"

rem ---------- 访问配置文件之前，先检测服务器网络连通性 ----------
echo.
echo.正在检测配置服务器网络连通性...大约需要6秒...请耐心等待...
ping -n 3 -w 2000 %SRV_IP%
if errorlevel 1 (
    echo.
    echo [错误] 无法连接到配置服务器 IP：%SRV_IP%
    echo 请检查：网络线缆是否插好、是否已接入内网、服务器 IP 是否正确。
    call :log "配置服务器 ping 失败：%SRV_IP%"
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)
call :log "配置服务器 ping 成功"
echo.
echo 网络连接成功！！！即将解析配置信息！！！
timeout 3 >nul


rem ---------- 通过网络读取 INI 配置文件（先读型号定义区，再读打印机信息区） ----------
cls
set "cfg_model_idx=0"
set "cfg_idx=0"
set "cfg_section="
if exist "%CFGFILE%" for /f "usebackq eol=; tokens=1,* delims==" %%a in ("%CFGFILE%") do call :load_config_line "%%a" "%%b"
call :log "配置解析：model_count=%cfg_model_idx% printer_count=%cfg_idx%"

if not defined MODEL_1 (
    echo.
    echo [错误] 配置文件中未找到 [MODELS] 型号定义区，或未定义任何型号：
    echo   %CFGFILE%
    echo 请确认共享服务器可访问、文件为 ANSI/GBK 编码，且包含 [MODELS] 区段。
    call :log "缺少 MODEL_1，退出"
    pause >nul
    exit /b 1
)
if not defined PRINTER_1 (
    echo.
    echo [错误] 配置文件中未找到 [PRINTERS] 打印机信息区，或列表为空：
    echo   %CFGFILE%
    echo 请确认共享服务器可访问、文件为 ANSI/GBK 编码，且包含 [PRINTERS] 区段。
    call :log "缺少 PRINTER_1，退出"
    pause >nul
    exit /b 1
)

echo.
echo 配置解析成功！！！即将渲染菜单！！！
timeout 3 >nul


:select_loop
cls
rem ============================================
rem  【动态渲染菜单】
rem ============================================
echo ========================================
echo         请选择要安装的打印机
echo ========================================

set "menu_index=0"
set "max_num=0"

rem 第一遍：找出最大编号
for /f "delims==" %%a in ('set PRINTER_ 2^>nul') do (
    for /f "tokens=2 delims=_" %%n in ("%%a") do (
        if %%n gtr !max_num! set "max_num=%%n"
    )
)

rem 第二遍：按数字顺序（1,2,3,...max_num）逐个显示
for /l %%i in (1,1,!max_num!) do (
    set "var_name=PRINTER_%%i"
    if defined !var_name! (
        rem 用 call 实现二次展开：先展开 !var_name! 得到 PRINTER_1，再展开对应的变量值
        call set "var_value=%%!var_name!%%"

        rem 提取名称（第一个|之前的内容）
        for /f "tokens=1 delims=|" %%p in ("!var_value!") do (
            echo [%%i] %%p
            set "menu_index=%%i"
        )
    )
)

echo ========================================
echo [0] 退出
echo ========================================

rem ============================================
rem  【用户交互选择】
rem ============================================
set /p SELECT_Interactive=请输入编号并回车: 

rem 检查是否为空输入
if not defined SELECT_Interactive goto select_loop

rem 检查是否为数字
echo(!SELECT_Interactive!|findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo 错误：请输入有效的数字！
    timeout 1 >nul
    goto select_loop
)

rem 检查是否为0（退出）
if "%SELECT_Interactive%"=="0" (
    call :log "用户选择 0 退出"
    echo 已退出安装
    if "!PCT_ERR!"=="0" if exist "%LOG%" del /f /q "%LOG%" >nul 2>&1
    exit /b
)

rem 检查是否存在对应的PRINTER_变量
set "selected_var=PRINTER_%SELECT_Interactive%"
if not defined %selected_var% (
    echo.
    echo 错误：编号 %SELECT_Interactive% 不存在，请重新选择！
    timeout 1 >nul
    goto select_loop
)

rem ============================================
rem  【获取选中的打印机名称】
rem ============================================
for /f "tokens=1 delims=|" %%p in ("!%selected_var%!") do set "SELECT=%%p"
call :log "用户选择编号 %SELECT_Interactive%，名称：!SELECT!"
echo ========================================
echo 您选择了：[%SELECT_Interactive%] !SELECT!
echo ========================================
timeout 3
cls

rem ---------- 根据 SELECT 获取对应的 IP 和型号 ----------
call :resolve_config %SELECT%
if errorlevel 1 (
    echo 错误: SELECT="%SELECT%" 无效，请检查配置！
    call :log "resolve_config 失败：%SELECT%"
    pause
    exit /b
)
call :log "解析结果 port=%port% drv_file=%drv_file% model_name=%model_name%"

rem ==============配置打印机名称================
rem 安装完成后显示的打印机名称：SELECT选择名@型号@port
rem 注意：pname 不带引号，只在作为命令参数时加引号，避免引号被带进名字里
set "pname=%SELECT%@%model_name:"=%@%port%"


rem ---------- 汇总显示当前配置信息 ----------
echo ========================================
echo 当前选择: %SELECT%
echo 端口号:   %port%
echo 共享路径: %DRV_PATH%
echo 驱动文件: %drv_file%
echo 完整路径: %DRV_PATH%%drv_file%
echo 打印机名: "%pname%"
echo ========================================
timeout 2
rem ---------- 连接打印机主逻辑 ----------

echo.
echo.正在检测打印机网络连通性...大约需要6秒...请耐心等待...
ping -n 3 -w 2000 %port%
if errorlevel 1 (
    echo.
    echo [错误] 无法连接到打印机 IP：%port%
    echo 请检查：网络线缆是否插好、打印机是否开机、IP 地址是否正确。
    call :log "打印机 ping 失败：%port%"
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)
call :log "打印机 ping 成功：%port%"
echo.
echo 网络连接成功！！！
echo.
timeout 2
cls

rem 添加打印端口
echo.
echo 正在创建打印机端口...请耐心等待...
echo.
if exist "%PRN_SCRIPTS%\prnport.vbs" (
    cscript //nologo "%PRN_SCRIPTS%\prnport.vbs" -a -r "%port%" -h %port% -o raw -n 9100
    set "prnport_err=!errorlevel!"
    call :log "prnport 完成，errorlevel=!prnport_err!"
) else (
    call :log "未找到 prnport.vbs，改用 PowerShell Add-PrinterPort"
    call :run_ps "Add-PrinterPort -Name '%port%' -HostAddress '%port%' -PortNumber 9100 -ErrorAction SilentlyContinue"
    set "prnport_err=!errorlevel!"
    call :log "Add-PrinterPort 完成，errorlevel=!prnport_err!"
)
if not "!prnport_err!"=="0" (
    set "PCT_ERR=1"
    call :log "创建打印机端口出错，已标记异常：errorlevel=!prnport_err!"
)


rem 添加打印机
echo.
echo 正在添加打印机...请耐心等待大约30秒...这不是卡住了...
printui /if /f "%DRV_PATH%%drv_file%" /r "%port%" /m %model_name% /b "%pname%"
set "pif_err=!errorlevel!"
call :log "printui /if 返回，errorlevel=!pif_err!"
if not "!pif_err!"=="0" (
    set "PCT_ERR=1"
    call :log "printui /if 返回异常，已标记异常：errorlevel=!pif_err!"
)

rem ------------------------------------------------------------
rem Win11 下 printui /if 返回后，打印队列可能仍在后台注册，
rem 立刻设置默认会“找不到打印机/设置无效”，这里先等待队列真正出现。
rem ------------------------------------------------------------
call :wait_printer "%pname%" 30
if errorlevel 1 (
    echo.
    echo [警告] 30 秒内未检测到打印队列已就绪，仍继续尝试设置默认。
    set "PCT_ERR=1"
    call :log "等待打印队列超时：%pname%"
) else (
    call :log "打印队列已就绪：%pname%"
)


rem 设置为默认打印机（多方式回退 + 校验，解决 Win11 设置不上的问题）
echo.
echo 正在将"%pname%"设置为默认打印机...

call :set_default "%pname%"
if errorlevel 1 (
    echo.
    echo [警告] 默认打印机未能确认设置成功。
    echo 打印机本身已经安装成功，可到“设置 - 蓝牙和其他设备 - 打印机和扫描仪”
    echo 中手动点击该打印机并选择“设为默认值”。
    set "PCT_ERR=1"
    call :log "默认打印机设置失败：%pname%"
) else (
    echo.
    echo "%pname%" - 已设置为默认打印机!
    call :log "默认打印机设置成功：%pname%"
)
echo.
echo.执行完毕，如果下面显示出打印机名称，使用该名称的打印机打印即可！
echo.
call :show_printer "%pname%"
echo.

rem ============================================
rem  打印测试页
rem  沿用原脚本的 choice 交互：10 秒内不选择默认 Y。
rem  原脚本用 if errorlevel 2 判断，但 choice 拿不到
rem  控制台输入时会返回 255，而 errorlevel 2 表示“>=2”，
rem  255 会被误当成选 N 直接 exit /b，导致窗口一闪而退。
rem  这里改为精确匹配 1/2，其他返回值兜底跳过但一定停在退出提示。
rem ============================================
choice /c YN /t 10 /d Y /m "是否打印测试页验证安装情况(10秒内未选择默认Y)"
set "tp_err=!errorlevel!"
if "!tp_err!"=="1" goto :tp_print
if "!tp_err!"=="2" goto :skip_testpage
echo.
echo [提示] 未能读取选择（errorlevel=!tp_err!），已跳过打印测试页。
goto :skip_testpage

:tp_print
echo.
echo 正在打印测试页...
if not exist "%PRN_SCRIPTS%\prnqctl.vbs" goto :tp_no_script
cscript //nologo "%PRN_SCRIPTS%\prnqctl.vbs" -e -p "%pname%"
set "tp_cmd_err=!errorlevel!"
call :log "测试页命令返回：errorlevel=!tp_cmd_err!"
if not "!tp_cmd_err!"=="0" set "PCT_ERR=1"
echo.
echo 如果打印机没有出纸，请自行打开一个文件实际打印确认。
echo 测试页失败并不代表安装失败，端口和打印队列已经创建成功。
goto :tp_finish

:tp_no_script
set "PCT_ERR=1"
call :log "未找到 prnqctl.vbs，跳过测试页打印"
echo 未找到系统打印测试页脚本，请自行打开文件实际打印确认。
goto :tp_finish

:skip_testpage
call :log "用户选择不打印测试页"
echo.
echo 已跳过打印测试页，打印机已安装完成，请自行打开文件实际打印确认。

:tp_finish
echo.
if "!PCT_ERR!"=="0" (
    echo 本次安装过程无异常，按任意键退出后将自动删除日志。
) else (
    echo [提示] 本次安装过程中出现过异常，日志将保留：%LOG%
)
echo.按任意键退出...
pause >nul
if "!PCT_ERR!"=="0" if exist "%LOG%" del /f /q "%LOG%" >nul 2>&1
exit /b 0


rem ============================================
rem  【日志子程序】
rem ============================================
:log
>>"%LOG%" echo [%DATE% %TIME%] %~1
goto :eof


rem ============================================
rem  【PowerShell 执行子程序】
rem  统一把输出写入日志，避免污染控制台
rem ============================================
:run_ps
if not exist "!PS!" goto :run_ps_fail
"!PS!" -NoProfile -ExecutionPolicy Bypass -Command "%~1" >>"%LOG%" 2>&1
exit /b %errorlevel%
:run_ps_fail
call :log "PowerShell 不存在，跳过：%~1"
exit /b 1


rem ============================================
rem  【等待打印队列就绪】
rem  通过注册表 Printers 子键判断，兼容 Win7~Win11
rem ============================================
:wait_printer
set "wn=%~1"
set "wlimit=%~2"
if not defined wlimit set "wlimit=30"
set /a wp_i=0
:wp_loop
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers\%wn%" >nul 2>&1
if not errorlevel 1 exit /b 0
set /a wp_i+=1
if !wp_i! geq !wlimit! exit /b 1
timeout 1 >nul
goto :wp_loop


rem ============================================
rem  【设置默认打印机】
rem  Win11 上 printui /n ... /y 经常静默失败，
rem  这里依次尝试 rundll32、printui、COM、CIM，并每次校验。
rem ============================================
:set_default
set "dn=%~1"
set "PCT_PRN=%dn%"
set /a sd_try=0

:sd_again
set /a sd_try+=1
call :log "设置默认打印机第 %sd_try% 次尝试：%dn%"

rem 方式1：rundll32 调用 printui 的 SetDefaultPrinter 入口（最稳）
rundll32 printui.dll,PrintUIEntry /y /n "%dn%"
timeout 1 >nul
call :check_default "%dn%"
if not errorlevel 1 goto :sd_ok

rem 方式2：printui /n /y
printui /n "%dn%" /y
timeout 1 >nul
call :check_default "%dn%"
if not errorlevel 1 goto :sd_ok

rem 方式3：PowerShell 的 WScript.Network COM 接口
call :run_ps "$w = New-Object -ComObject WScript.Network; $w.SetDefaultPrinter($env:PCT_PRN)"
timeout 1 >nul
call :check_default "%dn%"
if not errorlevel 1 goto :sd_ok

rem 方式4：CIM SetDefaultPrinter
call :run_ps "$p = Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $env:PCT_PRN }; if ($p) { Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter | Out-Null }"
timeout 1 >nul
call :check_default "%dn%"
if not errorlevel 1 goto :sd_ok

if !sd_try! lss 3 goto :sd_again
exit /b 1

:sd_ok
call :log "默认打印机已确认：%dn%"
exit /b 0


rem ============================================
rem  【校验默认打印机】
rem  优先用 PowerShell 判断，失败则退回注册表 Device 值
rem ============================================
:check_default
set "PCT_PRN=%~1"
call :run_ps "$d = Get-CimInstance Win32_Printer | Where-Object { $_.Default -and $_.Name -eq $env:PCT_PRN }; if ($d) { exit 0 } else { exit 1 }"
if not errorlevel 1 exit /b 0
set "dev="
for /f "tokens=2,*" %%a in ('reg query "HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v Device 2^>nul ^| findstr /i /c:"Device"') do set "dev=%%b"
echo(!dev! | findstr /i /c:"%PCT_PRN%" >nul
exit /b %errorlevel%


rem ============================================
rem  【显示已安装打印机名称】
rem  Win11 24H2 已移除 wmic，改用 Get-Printer；无该命令时直接回显
rem ============================================
:show_printer
set "PCT_PRN=%~1"
rem 替代原脚本的 wmic（Win11 24H2 已移除该命令）：
rem 1) Get-Printer（Win8+/Win11）  2) Get-WmiObject（Win7+）  3) 注册表  4) 直接回显
if not exist "!PS!" goto :sp_reg
"!PS!" -NoProfile -ExecutionPolicy Bypass -Command "$n = $env:PCT_PRN; try { Get-Printer -Name $n -ErrorAction Stop | ForEach-Object { $_.Name }; exit 0 } catch {}; $g = Get-WmiObject Win32_Printer | Where-Object { $_.Name -eq $n }; if ($g) { $g | ForEach-Object { $_.Name }; exit 0 }; exit 1" 2>nul
if not errorlevel 1 (
    call :log "已通过 Get-Printer/Get-WmiObject 显示打印机名称"
    exit /b 0
)
:sp_reg
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers\%PCT_PRN%" >nul 2>&1
if not errorlevel 1 (
    rem 注册表存在即说明队列已注册，直接显示名称
    echo %PCT_PRN%
    call :log "已通过注册表确认并显示打印机名称"
    exit /b 0
)
echo [提示] 未能确认打印机是否已注册，请到“打印机和扫描仪”中查看：
echo %PCT_PRN%
set "PCT_ERR=1"
call :log "注册表未找到打印机，仅回显名称：%PCT_PRN%"
exit /b 0


rem ============================================
rem  【INI 配置行解析子程序】
rem  【MODELS/PRINTERS 区段由文件中的 [MODELS]、[PRINTERS] 标题行切换】
rem ============================================
:load_config_line
set "ln_key=%~1"
set "ln_val=%~2"

if /i "%ln_key%"=="[MODELS]" goto :lc_sec_models
if /i "%ln_key%"=="[PRINTERS]" goto :lc_sec_printers
if /i "%cfg_section%"=="MODELS" goto :lc_add_model
if /i "%cfg_section%"=="PRINTERS" goto :lc_add_printer
goto :eof

:lc_sec_models
set "cfg_section=MODELS"
goto :eof

:lc_sec_printers
set "cfg_section=PRINTERS"
goto :eof

:lc_add_model
set /a cfg_model_idx+=1
set "MODEL_%cfg_model_idx%=%ln_key%|%ln_val%"
goto :eof

:lc_add_printer
set /a cfg_idx+=1
set "PRINTER_%cfg_idx%=%ln_key%|%ln_val%"
goto :eof

rem ============================================
rem  【配置解析子程序】
rem ============================================
:resolve_config
set "target=%~1"

rem 遍历所有 PRINTER_* 变量查找匹配的 SELECT 值
for /f "tokens=1,* delims==" %%a in ('set PRINTER_ 2^>NUL') do (
    for /f "tokens=1-3 delims=|" %%i in ("%%b") do (
        if "%%i"=="!target!" (
            set "port=%%j"
            set "model_tag=%%k"
            call :found %%k
            if errorlevel 1 (
                exit /b 1
            )
            exit /b 0
        )
    )
)
rem 未找到匹配
echo 错误: SELECT="%target%" 无效！
exit /b 1


:found
set "target_model=%~1"

rem 遍历所有 MODEL_* 变量查找匹配的型号标签
for /f "tokens=1,* delims==" %%a in ('set MODEL_ 2^>NUL') do (
    for /f "tokens=1-3 delims=|" %%i in ("%%b") do (
        if "%%i"=="!target_model!" (
            set "drv_file=%%j"
            rem 配置文件中型号名称不带引号，这里补上引号供 printui /m 使用
            set "model_name="%%k""
            exit /b 0
        )
    )
)

rem 未找到匹配的驱动配置
echo 错误: 未找到型号 "%target_model%" 的驱动配置！
exit /b 1
