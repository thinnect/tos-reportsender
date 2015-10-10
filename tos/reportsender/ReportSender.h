/**
 * @author Raido Pahtma
 * @license MIT
*/
#ifndef REPORTSENDER_H_
#define REPORTSENDER_H_

#include "sec_tmilli.h"

enum {
	REPORTSENDER_REPORT = 1,
	REPORTSENDER_REPORT_ACK = 2,
};

typedef nx_struct report_message_t {
	nx_uint8_t header; // 1 -- report
	nx_uint32_t report;
	nx_uint8_t fragment;
	nx_uint8_t total;
//	nx_uint8_t data[]; // Can't use, encountered nesC bug
} report_message_t;

typedef nx_struct report_message_ack_t {
	nx_uint8_t header; // 2 -- ack
	nx_uint32_t report;
//	nx_uint8_t missing[]; // Can't use, encountered nesC bug
} report_message_ack_t;

#ifndef REPORTSENDER_DELAY_MS
#define REPORTSENDER_DELAY_MS 100UL
#endif // REPORTSENDER_DELAY_MS

#ifndef REPORTSENDER_INTERVAL_MS
#define REPORTSENDER_INTERVAL_MS SEC_TMILLI(3UL)
#endif // REPORTSENDER_INTERVAL_MS

#ifndef REPORTSENDER_MAX_FRAGMENTS
#define REPORTSENDER_MAX_FRAGMENTS 3
#endif // REPORTSENDER_MAX_FRAGMENTS

#ifndef REPORTSENDER_RETRY_PERIOD_MIN_S
#define REPORTSENDER_RETRY_PERIOD_MIN_S 15
#endif // REPORTSENDER_RETRY_PERIOD_MIN_S

#ifndef REPORTSENDER_RETRY_PERIOD_MAX_S
#define REPORTSENDER_RETRY_PERIOD_MAX_S 900
#endif // REPORTSENDER_RETRY_PERIOD_MAX_S

#endif // REPORTSENDER_H_