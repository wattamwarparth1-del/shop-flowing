var fso = new ActiveXObject("Scripting.FileSystemObject");
var text = fso.OpenTextFile("assets/js/bundle.js", 1).ReadAll();
try {
    eval(text);
    WScript.Echo("Syntax OK!");
} catch (e) {
    WScript.Echo("Error: " + e.message);
    WScript.Echo("Line: " + (e.line || "unknown"));
}
