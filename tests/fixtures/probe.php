<?php
session_id(isset($_GET["id"]) ? $_GET["id"] : "php2shelltest");
session_start();
echo isset($_SESSION["upload_progress_probe"]) ? "unsafe\n" : "clean\n";
