<?php
set_error_handler(function ($severity, $message) {
    throw new ErrorException($message, 0, $severity);
});
register_shutdown_function(function () {
    // Exercise shutdown callbacks after an uncaught exception bailout.
    strlen("shutdown");
});
throw new Exception("intentional request failure");
