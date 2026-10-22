<?php
$array = new SplFixedArray(1);
$array->setSize(PHP_INT_SIZE === 8 ? 0x2000000000000001 : 0x40000001);
