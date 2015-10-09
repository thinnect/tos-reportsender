/**
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

	uint32_t m_report = 0;

	uint8_t m_current = g_channel_count;
	report_sender_t m_channels[g_channel_count];
	uint8_t m_missing[REPORTSENDER_MAX_FRAGMENTS];

	uint16_t m_retry_period_s = 0;

	typedef nx_struct report_struct_t {
		nx_uint8_t channel;
		nx_uint32_t id;
		nx_uint32_t ts_local_ms; // Local clock timestamp in milliseconds
		nx_uint32_t ts_clock_s; // RTC timestamp
		nx_uint8_t  data[255-13]; // This is limited by fragmenter/assembler currently
	} report_struct_t;

	report_struct_t m_report_buffer;
	uint8_t m_report_length = 0;

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

	task void nextReport()
	{
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
					}
					else if(err == EBUSY)
					{
						post nextReport();
					}
					else
					{
						m_channels[m_current].current++; // Skip this log item
						post nextReport();
					}
					return;
				}
			}
		}
		debug1("none");
	}

	event void Boot.booted()
	{
		debug1("c%u", g_channel_count);
		post nextReport();
	}

	task void sendTask()
	{
		if(call MessageQueue.size() > 0)
		{
			message_t* msg = call MessageQueue.dequeue();
			am_addr_t destination = AM_SERVER_ADDRESS;
			uint8_t length = call Packet.payloadLength(msg);
			error_t err = call AMSend.send(destination, msg, length);

			logger(err == SUCCESS ? LOG_DEBUG1 : LOG_ERR1, "snd(%04X,%p,%u)=%u (p%uq%u)", destination, msg, length, err, call MessagePool.size(), call MessageQueue.size());
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
	event void ST_RoutingResult.routed(am_addr_t destination, error_t result)
	{
		if(destination == AM_SERVER_ADDRESS)
		{
			logger(result == SUCCESS ? LOG_DEBUG1: LOG_WARN1, "routed %04X %u", destination, result);
			if(result == SUCCESS)
			{
				if(m_active)
				{
					m_retry_period_s = 0;
					call Timer.startOneShot(REPORTSENDER_RETRY_PERIOD_MIN_S * 1024UL);
				}
			}
		}
	}
#endif

	task void sendReport()
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
				call Timer.startOneShot(m_retry_period_s * 1024UL); // run retry

				post sendTask();
			}
			else // pool had to be completely empty, so try again a bit later
			{
				call Timer.startOneShot(REPORTSENDER_INTERVAL_MS);
			}
		}
	}

	event void Timer.fired()
	{
		if(call MessageQueue.empty())
		{
			post sendReport();
		}
		else
		{
			call Timer.startOneShot(REPORTSENDER_RETRY_PERIOD_MIN_S * 1024UL); // Still sending old fragments, retry later
		}
	}

	event void GetReport.report[uint8_t reporter](error_t result, uint32_t id, uint32_t timestampmilli, uint8_t data[], uint8_t length)
	{
		logger(result == SUCCESS ? LOG_DEBUG1: LOG_WARN1, "rprt[%u](%u,%"PRIu32",%"PRIu32",%p,%u)", reporter, result, id, timestampmilli, data, length);
		if(result == SUCCESS)
		{
			uint16_t rlen = sizeof(m_report_buffer) - sizeof(m_report_buffer.data) + length;
			if(rlen <= sizeof(m_report_buffer))
			{
				time64_t timestamp = call RealTimeClock.time() - (time64_t)((call LocalTimeMilli.get() - timestampmilli)/SEC_TMILLI(1)); // Calculate the RTC timestamp of the report = now - age_ms/ms
				uint8_t i;
				uint8_t fragments = data_fragments(rlen, call AMSend.maxPayloadLength() - sizeof(report_message_t));
				m_report_buffer.channel = call GetReport.channel[reporter]();
				m_report_buffer.id = id;
				m_report_buffer.ts_local_ms = timestampmilli;
				m_report_buffer.ts_clock_s = yxktime(&timestamp);
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

		post nextReport();
	}

	event void GetReport.newReport[uint8_t reporter](uint32_t id)
	{
		if(id > 0)
		{
			info1("new rprt %u:%"PRIu32, reporter, id);
			m_channels[reporter].latest = id; // remember ID
			if(m_active == FALSE)
			{
				post nextReport();
			}
		}
	}

	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len)
	{
		debug1("RCV %u", len);
		if(len >= sizeof(report_message_ack_t))
		{
			report_message_ack_t* rma = (report_message_ack_t*)payload;
			if(rma->header == REPORTSENDER_REPORT_ACK)
			{
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
						debugb1("miss %u", m_missing, REPORTSENDER_MAX_FRAGMENTS, missing);

						while(call MessageQueue.size() > 0)
						{
							debug1("clear");
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
						call Timer.stop();
						post nextReport();
					}
				}
				else warn1("rprt %"PRIu32"!=%"PRIu32, rma->report, m_report);
			}
			else warn1("hdr %u", rma->header);
		}
		else warn1("len %u", len);
		return msg;
	}

	async event void RealTimeClock.changed(time64_t old, time64_t current) { }

	default command uint8_t GetReport.channel[uint8_t reporter]()
	{
		return 0;
	}

	default command error_t GetReport.get[uint8_t reporter](uint32_t id)
	{
		return EINVAL;
	}

}
