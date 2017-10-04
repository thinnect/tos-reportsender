/**
 * Diagnostic report sender. Attempts to reliably deliver all reports.
 * The reportsender is reset at boot.
 *
 * @author Raido Pahtma
 * @license MIT
*/
#include "fragmenter_assembler.h"
#include "ReportSender.h"
generic module ReportSenderP(uint8_t g_channel_count) {
	provides {
		interface Init;
	}
	uses {
		interface Boot;
		#ifdef STACK_BEAT
		interface ST_RoutingResult;
		#endif
		interface AMSend;
		interface AMPacket;
		interface Packet;
		interface Receive;
		interface GetReport[uint8_t channel_index];
		interface Timer<TMilli>;
		interface Pool<message_t> as MessagePool;
		interface Queue<message_t*> as MessageQueue;

		interface LocalTime<TMilli> as LocalTimeMilli;
		interface RealTimeClock;
	}
}
implementation {

	#define __MODUUL__ "rpsnd"
	#define __LOG_LEVEL__ ( LOG_LEVEL_ReportSenderP & BASE_LOG_LEVEL )
	#include "log.h"

	typedef struct report_sender_t {
		uint32_t latest; // > 0
		uint32_t current; // Nothing to deliver, if current > latest
	} report_sender_t;

	bool m_active = FALSE;
	bool m_next = TRUE;

	uint32_t m_report = 0;

	uint8_t m_current = g_channel_count;
	report_sender_t m_channels[g_channel_count];
	uint8_t m_missing[REPORTSENDER_MAX_FRAGMENTS];

	uint16_t m_retry_period_s = 0;

	am_addr_t m_destination = AM_BROADCAST_ADDR; // Initial destination is broadcast, ack to reset message will get a unicast address here

	typedef nx_struct report_struct_t {
		nx_uint8_t channel;
		nx_uint32_t id;
		nx_uint32_t ts_local_ms; // Local clock timestamp in milliseconds
		nx_uint32_t ts_clock_s; // RTC timestamp
		nx_uint8_t  data[255-13]; // This is limited by fragmenter/assembler currently
	} report_struct_t;

	report_struct_t m_report_buffer;
	uint8_t m_report_length = 0;

	task void reportingTask();

	command error_t Init.init()
	{
		uint8_t i;
		for(i=0;i<g_channel_count;i++)
		{
			m_channels[i].latest = 0;
			m_channels[i].current = 1;
		}
		return SUCCESS;
	}

	/**
	 * Send the next report. The first report is always a RESET report with ID 0.
	 */
	void nextReport()
	{
		time64_t rtcnow = call RealTimeClock.time();
		if(rtcnow != (time64_t)(-1))
		{
			m_next = FALSE;
			if(m_report == 0)
			{
				debug1("init");
				m_retry_period_s = 0;
				m_active = TRUE;
				signal GetReport.report[g_channel_count](SUCCESS, 0, 0, NULL, 0);
				return;
			}
			else
			{
				uint8_t i;
				for(i=0;i<g_channel_count;i++)
				{
					m_current = (m_current + 1) % g_channel_count; // If idle, it actually starts from second slot and will get to the first slot last
					debug1("rprtr %u (%"PRIu32"/%"PRIu32")", m_current, m_channels[m_current].current, m_channels[m_current].latest);
					if(m_channels[m_current].current <= m_channels[m_current].latest)
					{
						error_t err = call GetReport.get[m_current](m_channels[m_current].current);
						logger(err == SUCCESS ? LOG_DEBUG1 : LOG_ERR1, "get[%u](%"PRIu32")=%u", m_current, m_channels[m_current].current, err);
						if(err == SUCCESS)
						{
							m_retry_period_s = 0;
							m_active = TRUE;
							return;
						}

						if(err != EBUSY) // With EBUSY just try the same one again
						{
							m_channels[m_current].current++; // Skip this log item
						}
						m_next = TRUE;
						call Timer.startOneShot(REPORTSENDER_DELAY_MS);
						return;
					}
				}
				debug1("none");
			}
		}
		else {
			debug1("wait rtc");
		}
	}

	event void Boot.booted()
	{
		debug1("c%u", g_channel_count);
		post reportingTask();
	}

	task void sendTask()
	{
		if(call MessageQueue.size() > 0)
		{
			message_t* msg = call MessageQueue.dequeue();
			uint8_t length = call Packet.payloadLength(msg);
			error_t err = call AMSend.send(m_destination, msg, length);

			logger(err == SUCCESS ? LOG_DEBUG1 : LOG_ERR1, "snd(%04X,%p,%u)=%u (p%uq%u)", m_destination, msg, length, err, call MessagePool.size(), call MessageQueue.size());
			if(err != SUCCESS)
			{
				call MessagePool.put(msg);
				post sendTask();
			}
		}
	}

	event void AMSend.sendDone(message_t* msg, error_t result)
	{
		logger(result == SUCCESS ? LOG_DEBUG1 : LOG_WARN1, "sD(%p,%u)", msg, result);
		call MessagePool.put(msg);
		post sendTask();
	}


#ifdef STACK_BEAT
	event void ST_RoutingResult.routed(am_addr_t destination, route_cost_t dist, error_t result)
	{
		if(destination == m_destination)
		{
			logger(result == SUCCESS ? LOG_DEBUG1: LOG_WARN1, "routed %04X %u", destination, result);
			if(result == SUCCESS)
			{
				if(m_active)
				{
					m_retry_period_s = 0;
					call Timer.startOneShot(SEC_TMILLI(REPORTSENDER_RETRY_PERIOD_MIN_S));
				}
			}
		}
	}
#endif

	void sendReport()
	{
		if(m_active)
		{
			uint8_t max_fragment_size = call AMSend.maxPayloadLength() - sizeof(report_message_t);
			uint8_t fragments = data_fragments(m_report_length, max_fragment_size);
			uint8_t i;

			debugb1("miss", m_missing, REPORTSENDER_MAX_FRAGMENTS);
			for(i=0;i<REPORTSENDER_MAX_FRAGMENTS;i++)
			{
				if((m_missing[i] != 0xFF) && (call MessageQueue.size() < call MessageQueue.maxSize()))
				{
					message_t* msg = call MessagePool.get();
					if(msg != NULL)
					{
						report_message_t* rm = call AMSend.getPayload(msg, sizeof(report_message_t) + max_fragment_size);
						if(rm != NULL)
						{
							error_t err;
							uint8_t fragment_size;
							uint8_t* payload = (uint8_t*)rm + sizeof(report_message_t);
							rm->header = REPORTSENDER_REPORT;
							rm->report = m_report;
							rm->fragment = m_missing[i];
							rm->total = fragments;
							fragment_size = data_fragmenter(payload, max_fragment_size, m_missing[i]*max_fragment_size, (uint8_t*)&m_report_buffer, m_report_length);
							call Packet.setPayloadLength(msg, sizeof(report_message_t) + fragment_size);

							err = call MessageQueue.enqueue(msg);
							if(err != SUCCESS)
							{
								err1("q%u", err);
								call MessagePool.put(msg);
								break;
							}
						}
					}
					else // Not enough messages available currently
					{
						debug1("pool");
						break;
					}
				}
				else // Nothing to send or can't send anything anymore at the moment
				{
					debug1("break %u %u", i, call MessageQueue.size());
					break;
				}
			}

			if(call MessageQueue.size() > 0) // sent something, wait for ack or retry
			{
				if(m_retry_period_s < REPORTSENDER_RETRY_PERIOD_MAX_S)
				{
					m_retry_period_s += REPORTSENDER_RETRY_PERIOD_MIN_S;
				}

				debug1("n %us", m_retry_period_s);
				call Timer.startOneShot(SEC_TMILLI(m_retry_period_s)); // run retry

				post sendTask();
			}
			else // pool had to be completely empty, so try again a bit later
			{
				call Timer.startOneShot(REPORTSENDER_INTERVAL_MS);
			}
		}
	}

	task void reportingTask()
	{
		debug1("rprtng");
		if(m_next)
		{
			nextReport();
		}
		else if(call MessageQueue.empty())
		{
			sendReport();
		}
		else
		{
			call Timer.startOneShot(SEC_TMILLI(REPORTSENDER_RETRY_PERIOD_MIN_S)); // Still sending old fragments, retry later
		}
	}

	event void Timer.fired()
	{
		debug1("tmr %"PRIu32, call Timer.getNow());
		post reportingTask();
	}

	event void GetReport.report[uint8_t reporter](error_t result, uint32_t id, uint32_t timestampmilli, uint8_t data[], uint8_t length)
	{
		logger(result == SUCCESS ? LOG_DEBUG1: LOG_WARN1, "rprt[%u](%u,%"PRIu32",%"PRIu32",%p,%u)", reporter, result, id, timestampmilli, data, length);
		if(result == SUCCESS)
		{
			uint16_t rlen = sizeof(m_report_buffer) - sizeof(m_report_buffer.data) + length;
			if(rlen <= sizeof(m_report_buffer))
			{
				time64_t rtcnow = call RealTimeClock.time();
				uint8_t i;
				uint8_t fragments = data_fragments(rlen, call AMSend.maxPayloadLength() - sizeof(report_message_t));

				m_report_buffer.channel = call GetReport.channel[reporter]();
				m_report_buffer.id = id;
				m_report_buffer.ts_local_ms = timestampmilli;

				if(rtcnow != (time64_t)(-1))
				{   // Calculate the RTC timestamp of the report = now - age_ms/ms_per_sec
					time64_t timestamp = rtcnow - (time64_t)((call LocalTimeMilli.get() - timestampmilli)/SEC_TMILLI(1));
					m_report_buffer.ts_clock_s = yxktime(&timestamp);
				}
				else
				{   // This should not happen unless someone explicitly sets the clock to -1
					warn1("rtc -1");
					m_report_buffer.ts_clock_s = 0;
				}

				memcpy(m_report_buffer.data, data, length);
				m_report_length = rlen;

				for(i=0;i<REPORTSENDER_MAX_FRAGMENTS;i++)
				{
					if(i < fragments)
					{
						m_missing[i] = i;
					}
					else
					{
						m_missing[i] = 0xFF;
					}
				}

				call Timer.startOneShot(REPORTSENDER_INTERVAL_MS);
				return;
			}
			else warn1("too long %u", rlen);
		}
		else warn1("no rprt %u:%"PRIu32, reporter, m_channels[reporter].current);

		if(reporter < g_channel_count)
		{
			m_channels[reporter].current++;
		}
		m_active = FALSE;

		m_next = TRUE;
		call Timer.startOneShot(0);
	}

	event void GetReport.newReport[uint8_t reporter](uint32_t id)
	{
		if(id > 0)
		{
			info1("new rprt %u:%"PRIu32, reporter, id);
			m_channels[reporter].latest = id; // remember ID
			if(m_active == FALSE)
			{
				m_next = TRUE;
				call Timer.startOneShot(0);
			}
		}
	}

	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len)
	{
		if(len >= sizeof(report_message_ack_t))
		{
			report_message_ack_t* rma = (report_message_ack_t*)payload;
			switch(rma->header)
			{
				case REPORTSENDER_REPORT:
					debug1("rprt %04X->%04X l%u", call AMPacket.source(msg), call AMPacket.destination(msg), len);
					break;
				case REPORTSENDER_REPORT_ACK:
					if(rma->report == m_report)
					{
						uint8_t missing = len - sizeof(report_message_ack_t);
						if(missing > 0)
						{
							uint8_t* data = ((uint8_t*)rma) + sizeof(report_message_ack_t);
							if(missing < REPORTSENDER_MAX_FRAGMENTS)
							{
								memcpy(m_missing, data, missing);
								memset(m_missing + missing, 0xFF, REPORTSENDER_MAX_FRAGMENTS - missing);
							}
							else
							{
								memcpy(m_missing, data, REPORTSENDER_MAX_FRAGMENTS);
							}
							debugb2("miss %u", m_missing, REPORTSENDER_MAX_FRAGMENTS, missing);

							while(call MessageQueue.size() > 0)
							{
								debug2("clear");
								call MessagePool.put(call MessageQueue.dequeue()); // Throw away old stuff in the queue
							}

							m_retry_period_s = 0; // Contact possible, reset retry timeout and speed things up

							call Timer.startOneShot(REPORTSENDER_INTERVAL_MS); // Retrieve data and send
						}
						else
						{
							if(m_current < g_channel_count)
							{
								m_channels[m_current].current++;
							}
							m_report++;

							m_active = FALSE;
							m_next = TRUE;
							call Timer.startOneShot(0);
						}
						debug1("ack %04X r%"PRIu32" m%u", call AMPacket.source(msg), rma->report, missing);
						m_destination = call AMPacket.source(msg); // Initially broadcast, but assume one interested party in the whole world and send everything to them
					}
					else warn1("rprt %"PRIu32"!=%"PRIu32, rma->report, m_report);
					break;
				default:
					warnb1("hdr %u", payload, len, rma->header);
					break;
			}
		}
		else warn1("len %u", len);
		return msg;
	}

	async event void RealTimeClock.changed(time64_t old, time64_t current)
	{
		post reportingTask();
	}

	default command uint8_t GetReport.channel[uint8_t reporter]()
	{
		return 0;
	}

	default command error_t GetReport.get[uint8_t reporter](uint32_t id)
	{
		return EINVAL;
	}

}
