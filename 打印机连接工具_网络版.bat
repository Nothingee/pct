@echo off & PUSHD %~DP0 & TITLE 打印机连接工具增强版-如有连接失败和异常需要技术支持请联系IT中心运维组-姚志明
setlocal enabledelayedexpansion

rem exit /b 错误码：0代表正常结束，1代表异常结束

rem ============================================
rem  【脚本管理员权限验证】
rem ============================================
>NUL 2>&1 REG.exe query "HKU\S-1-5-19" || (
    ECHO SET UAC = CreateObject^("Shell.Application"^) > "%TEMP%\Getadmin.vbs"
    ECHO UAC.ShellExecute "%~f0", "%1", "", "runas", 1 >> "%TEMP%\Getadmin.vbs"
    "%TEMP%\Getadmin.vbs"
    DEL /f /q "%TEMP%\Getadmin.vbs" 2>NUL
    Exit /b
)

rem ============================================
rem  【对于Win11的操作前置条件处理】
rem ============================================
rem 禁用 SMB 客户端签名要求
powershell -Command "Set-SmbClientConfiguration -RequireSecuritySignature $false -Force" 2>NUL
rem 启用不安全的来宾登录
powershell -Command "Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force" 2>NUL

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
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)
echo.
echo 网络连接成功！！！即将解析配置信息！！！
timeout 3 >nul


rem ---------- 通过网络读取 INI 配置文件（先读型号定义区，再读打印机信息区） ----------
cls
set "cfg_model_idx=0"
set "cfg_idx=0"
set "cfg_section="
if exist "%CFGFILE%" for /f "usebackq eol=; tokens=1,* delims==" %%a in ("%CFGFILE%") do call :load_config_line "%%a" "%%b"

if not defined MODEL_1 (
    echo.
    echo [错误] 配置文件中未找到 [MODELS] 型号定义区，或未定义任何型号：
    echo   %CFGFILE%
    echo 请确认共享服务器可访问、文件为 ANSI/GBK 编码，且包含 [MODELS] 区段。
    pause >nul
    exit /b 1
)
if not defined PRINTER_1 (
    echo.
    echo [错误] 配置文件中未找到 [PRINTERS] 打印机信息区，或列表为空：
    echo   %CFGFILE%
    echo 请确认共享服务器可访问、文件为 ANSI/GBK 编码，且包含 [PRINTERS] 区段。
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
echo %SELECT_Interactive%|findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo 错误：请输入有效的数字！
    timeout 1 >nul
    goto select_loop
)

rem 检查是否为0（退出）
if "%SELECT_Interactive%"=="0" (
    echo 已退出安装
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
for /f "tokens=2 delims==" %%v in ('set %selected_var% 2^>nul') do (
    for /f "tokens=1 delims=|" %%p in ("%%v") do (
        set "SELECT=%%p"
    )
)
echo ========================================
echo 您选择了：[%SELECT_Interactive%] !SELECT!
echo ========================================
timeout 3
cls

rem ============================================
rem  【配置选择区】- 修改这里选择要安装的打印机
rem ============================================
rem set SELECT=%SELECT_Interactive%
rem 可选值: SELECT列表=号右边的值
rem ============================================




rem ---------- 根据 SELECT 获取对应的 IP 和型号 ----------
call :resolve_config %SELECT%
if errorlevel 1 (
    echo 错误: SELECT="%SELECT%" 无效，请检查配置！
    pause
    exit /b
)

rem ==============配置打印机名称================
rem 安装完成后显示的打印机名称：SELECT选择名@型号@port
set printer_name="%SELECT%@%model_name:"=%@%port%"


rem ---------- 汇总显示当前配置信息 ----------
echo ========================================
echo 当前选择: %SELECT%
echo 端口号:   %port%
echo 共享路径: %DRV_PATH%
echo 驱动文件: %drv_file%
echo 完整路径: %DRV_PATH%%drv_file%
echo 打印机名: %printer_name%
echo ========================================
timeout 2
rem ---------- 连接打印机主逻辑 ----------

echo.
echo.正在检测网络连通性...大约需要6秒...请耐心等待...
ping -n 3 -w 2000 %port%
if errorlevel 1 (
    echo.
    echo [错误] 无法连接到打印机 IP：%port%
    echo 请检查：网络线缆是否插好、打印机是否开机、IP 地址是否正确。
    echo.
    echo.按任意键退出...
    pause >nul
    exit /b 1
)
echo.
echo 网络连接成功！！！


rem 添加打印端口
echo.
echo 正在创建打印机端口...请耐心等待...
cscript //nologo %WINDIR%\System32\Printing_Admin_Scripts\zh-CN\prnport.vbs -a -r "%port%" -h %port% -o raw -n 9100



rem 添加打印机
echo.
echo 正在添加打印机...请耐心等待大约30秒...这不是卡住了...
printui /if /f "%DRV_PATH%%drv_file%" /r "%port%" /m %model_name% /b %printer_name%


rem 关闭"让Windows管理我的默认打印机"
echo.
echo 正在准备设置默认打印机...请耐心等待....
REG ADD "HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v "LegacyDefaultPrinterMode" /t REG_DWORD /d "1" /f >nul 2>&1

rem 设置为默认打印机
echo.
echo 正在将 %printer_name% 设置为默认打印机...
printui /n %printer_name% /y
echo %printer_name% - 已设置为默认打印机!
echo.
echo.执行完毕，如果下面显示出打印机名称，使用该名称的打印机打印即可！
echo.
wmic printer where Name=%printer_name% get name | findstr /v "Name"
echo.
choice /c YN /t 10 /d Y /m "是否打印测试页验证安装情况(10秒内未选择默认Y)"
if errorlevel 2 (
    exit /b
) else if errorlevel 1 (
    cscript //nologo %WINDIR%\System32\Printing_Admin_Scripts\zh-CN\prnqctl.vbs -e -p %printer_name%
    rem control printers
    echo.按任意键退出...
    pause >nul
)

exit /b

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