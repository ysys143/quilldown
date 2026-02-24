const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, '..', '..', 'Quilldown', 'Resources');
const dstDir = path.join(__dirname, '..', 'src');

if (!fs.existsSync(srcDir)) {
    console.log('Resources directory not found, skipping copy');
    process.exit(0);
}

const entries = fs.readdirSync(srcDir);
for (const entry of entries) {
    const srcPath = path.join(srcDir, entry);
    const dstPath = path.join(dstDir, entry);
    const stat = fs.statSync(srcPath);

    if (stat.isDirectory()) {
        fs.cpSync(srcPath, dstPath, { recursive: true, force: true });
    } else {
        // Don't overwrite index.html with render.html
        if (entry === 'render.html') continue;
        fs.copyFileSync(srcPath, dstPath);
    }
}

console.log('Shared resources copied to quilldown-tauri/src/');
