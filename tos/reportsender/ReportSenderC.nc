/**
 * @author Raido Pahtma
 * @license MIT
*/
configuration ReportSenderC {
	uses interface GetReport[uint8_t reporter];
}
implementation {

	components new ReportSenderP(uniqueCount("reportsender.reporter"));
	ReportSenderP.GetReport = GetReport;

	components MainC;
	ReportSenderP.Boot -> MainC;
	MainC.SoftwareInit -> ReportSenderP.Init;

	components LocalTimeMilliC;
	ReportSenderP.LocalTimeMilli -> LocalTimeMilliC;

	components RealTimeClockC;
	ReportSenderP.RealTimeClock -> RealTimeClockC;

	components new TimerMilliC();
	ReportSenderP.Timer -> TimerMilliC;

	components new AMSenderC(9);
	ReportSenderP.AMSend -> AMSenderC;
	ReportSenderP.Packet -> AMSenderC;

	components new AMReceiverC(9);
	ReportSenderP.Receive -> AMReceiverC;

	#ifdef STACK_BEAT
	components STackC;
	ReportSenderP.ST_RoutingResult -> STackC;
	#endif // STACK_BEAT

	components GlobalPoolC;
	ReportSenderP.MessagePool -> GlobalPoolC;

	components new QueueC(message_t*, 2);
	ReportSenderP.MessageQueue -> QueueC;

}
