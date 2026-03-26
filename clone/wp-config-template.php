<?php


/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the installation.
 * You don't have to use the web site, you can copy this file to "wp-config.php"
 * and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * Database settings
 * * Secret keys
 * * Database table prefix
 * * Localized language
 * * ABSPATH
 *
 * @link https://wordpress.org/support/article/editing-wp-config-php/
 *
 * @package WordPress
 */

// ** Database settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define( 'DB_NAME', 'CLONE_DB_USER' );

/** Database username */
define( 'DB_USER', 'CLONE_DB_USER' );

/** Database password */
define( 'DB_PASSWORD', 'CLONE_DB_PASS' );

/** Database hostname */
define( 'DB_HOST', 'localhost' );

/** Database charset to use in creating database tables. */
define( 'DB_CHARSET', 'utf8' );

/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', '' );

/**#@+
 * Authentication unique keys and salts.
 *
 * Change these to different unique phrases! You can generate these using
 * the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}.
 *
 * You can change these at any point in time to invalidate all existing cookies.
 * This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
define('AUTH_KEY', 'kK6H0Q+Ju@(caRNKajJsAvBr-Sa6!Z/xxe#3D%63%&Nkj6A3*-#)h[g0J36Ky@cC');
define('SECURE_AUTH_KEY', '67N7bO&5//E~UP2(O8lpZ]h)|A*n3f*(29Ux/!1Yj/jJ198A#488#8x7!6Gk60AP');
define('LOGGED_IN_KEY', 'I4/V@fJ)740g#n91_7x@bm6uhlBzgL44&O64Y2:]g4vXQ(715Mb*/+VbS1a(]w2b');
define('NONCE_KEY', '/cWF%|3n83/xMNG%:l+5HaI_WR;x]ke0(5~tXv547Cs;AfriA|UAn!(bC2t]K4t*');
define('AUTH_SALT', '](F#nJntgpkOI+6l&HjN:8X4Q/!9n9K4frD[A)-L6y7@3g8KK+XO29217a2NHY+r');
define('SECURE_AUTH_SALT', '0!_c67T2V+@sxa4ZFB:8do(:)--|4p_QX3/9i*E*o2ys7&Y*tA5Ix5ejP2mee~ii');
define('LOGGED_IN_SALT', 'JzX@0O]J+6bP)v9-/pJ|A_h;hsPoaD4B6wn;&*)i6kNh(Q]7)1-l!fm:f61:jTZ[');
define('NONCE_SALT', '%*9Iz8K9x64d192e9Y!*7%oM|dDX#0//WM37Y2Q_vmth%9t64Rbnc55-O)k1N3/t');


/**#@-*/

/**
 * WordPress database table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 */
$table_prefix = 'oXxhsA_';


/* Add any custom values between this line and the "stop editing" line. */

define('WP_ALLOW_MULTISITE', true);
/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the documentation.
 *
 * @link https://wordpress.org/support/article/debugging-in-wordpress/
 */
if ( ! defined( 'WP_DEBUG' ) ) {
	define( 'WP_DEBUG', false );
}

define( 'WP_DEBUG_DISPLAY', false );
define( 'WP_DEBUG_LOG', true );
define( 'WP_REDIS_SCHEME', 'unix' );
define( 'WP_REDIS_PATH', '/run/redis/redis-server.sock' );
define( 'WP_REDIS_DATABASE', 0 );
define( 'WP_CACHE_KEY_SALT', 'CLONE_DOMAIN_' );
/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';

// Redis Object Cache

// Disable WP-Cron (use system cron)
define('DISABLE_WP_CRON', true);
